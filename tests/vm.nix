# End-to-end check that the packaged client is wired up correctly.
#
# It deliberately asserts the three things that silently break a Nix packaging
# of Windscribe: realpath("/opt/windscribe") inside the helper's namespace, the
# setgid path to the helper socket, and the protocol binaries actually running.
#
# The helper-socket probe is written in Python rather than shell on purpose: a
# setgid bash drops its effective gid back to the real one as a privileged-mode
# guard, which would mask the very group the wrapper grants. The real engine is
# a compiled binary and keeps it.
{
  self,
  variant ? "gui",
}:
{ lib, pkgs, ... }:
let
  helperProbe = pkgs.writers.writePython3 "windscribe-helper-probe" { } ''
    import socket
    import sys

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.connect("/run/windscribe/helper.sock")
    except OSError as exc:
        print("connect failed:", exc)
        sys.exit(1)
    print("connected")
  '';
in
{
  name = "windscribe-${variant}";

  nodes.machine =
    { config, ... }:
    {
      imports = [ self.nixosModules.windscribe ];

      services.windscribe = {
        enable = true;
        inherit variant;
      };

      virtualisation.memorySize = if variant == "gui" then 3072 else 2048;
      virtualisation.diskSize = 4096;

      # A desktop user who is deliberately NOT in the windscribe group: that is
      # how somebody actually launches the client, and it is what makes the
      # setgid assertions below mean something.
      users.users.alice = {
        isNormalUser = true;
        uid = 1000;
      };

      services.resolved.enable = true;

      # Qt refuses to come up without a single usable font, and a test VM has none.
      fonts.enableDefaultPackages = lib.mkIf (variant == "gui") true;

      # At runtime the package tree only exists inside the helper's mount
      # namespace, so expose it at a fixed path for the test to poke at.
      environment.etc."windscribe-package".source = config.services.windscribe.package;

      environment.etc."windscribe-helper-probe" = {
        source = helperProbe;
        mode = "0755";
      };

      # Same probe, reached through the exact mechanism the engine uses.
      security.wrappers.windscribe-helper-probe = {
        source = helperProbe;
        owner = "root";
        group = "windscribe";
        setgid = true;
      };

      environment.systemPackages = lib.optionals (variant == "gui") [
        pkgs.xvfb-run
        pkgs.xorg.xorgserver
      ];
    };

  testScript = ''
    pkg = "/etc/windscribe-package/opt/windscribe"

    machine.wait_for_unit("windscribe-helper.service")
    machine.wait_for_file("/run/windscribe/helper.sock")

    with subtest("helper PATH was rewritten away from the FHS default"):
        # src/helper/linux/main.cpp overrides PATH before anything can spawn a
        # child, so leaving the original literal in place breaks ip, nmcli,
        # modprobe, pkill and resolvectl all at once.
        machine.fail(f"grep -qa '/usr/sbin:/usr/bin:/sbin:/bin' {pkg}/helper")
        machine.succeed(f"grep -qa '/etc/windscribe/bin' {pkg}/helper")
        for tool in ["ip", "pkill", "modprobe", "resolvectl", "systemctl", "wg"]:
            machine.succeed(f"test -x /etc/windscribe/bin/{tool}")

    with subtest("the helper sees a real /opt/windscribe"):
        # resolveExePath() compares realpath("/opt/windscribe") against its
        # compile-time install dir, and refuses to exec anything if they differ.
        pid = machine.succeed(
            "systemctl show -p MainPID --value windscribe-helper.service"
        ).strip()
        machine.succeed(f"nsenter -t {pid} -m -- test -x /opt/windscribe/helper")
        resolved = machine.succeed(
            f"nsenter -t {pid} -m -- readlink -f /opt/windscribe"
        ).strip()
        assert resolved == "/opt/windscribe", f"realpath gave {resolved!r}"

    with subtest("every protocol binary runs"):
        # OpenVPN covers UDP and TCP, wstunnel covers WSTunnel and is also what
        # Stealth proxies through, amneziawg is the userspace WireGuard
        # fallback, and ctrld backs Connected DNS.
        print(machine.succeed(f"{pkg}/windscribeopenvpn --version | head -n1"))
        print(machine.succeed(f"{pkg}/windscribeamneziawg --version"))
        print(machine.succeed(f"{pkg}/windscribectrld --version"))
        machine.succeed(f"{pkg}/windscribewstunnel --help > /dev/null")

    with subtest("the kill switch has the pieces it needs"):
        # buildFirewallRules fails the whole apply when getpwnam("windscribe")
        # misses, which takes Stealth and WSTunnel down with it.
        machine.succeed("getent passwd windscribe")
        machine.succeed("getent group windscribe")
        machine.succeed("/etc/windscribe/bin/wg --version")

    with subtest("platform marker matches the installed variant"):
        platform = machine.succeed("cat /etc/windscribe/platform").strip()
        assert platform == "${
          if variant == "gui" then "linux_deb_x64" else "linux_deb_x64_cli"
        }", platform

    with subtest("the helper socket is group-gated"):
        group = machine.succeed("stat -c %G /run/windscribe/helper.sock").strip()
        assert group == "windscribe", f"socket group is {group!r}"
        machine.fail("su alice -c /etc/windscribe-helper-probe")

    with subtest("a setgid wrapper gets a plain user to the helper"):
        machine.succeed("test -g /run/wrappers/bin/windscribe-engine")
        group = machine.succeed(
            "stat -c %G /run/wrappers/bin/windscribe-engine"
        ).strip()
        assert group == "windscribe", f"wrapper group is {group!r}"
        machine.succeed("su alice -c /run/wrappers/bin/windscribe-helper-probe")

    with subtest("the engine starts and reaches the helper"):
        # Absolute path: systemd-run resolves only the command it is given,
        # and a transient unit does not inherit the login PATH.
        launch = "${
          if variant == "gui" then
            "xvfb-run -a /run/current-system/sw/bin/windscribe"
          else
            "/run/current-system/sw/bin/windscribe"
        }"
        machine.succeed("loginctl enable-linger alice")
        machine.succeed(
            "systemd-run --unit=ws-engine --collect --uid=alice "
            "--setenv=HOME=/home/alice --setenv=XDG_RUNTIME_DIR=/run/user/1000 "
            f"{launch}"
        )
        machine.sleep(30)
        print(machine.succeed("journalctl -u ws-engine --no-pager | tail -n 60 || true"))
        # Failing to reach the helper socket is the classic symptom of a broken
        # Nix packaging and shows up as the engine exiting during startup.
        machine.succeed("pgrep -u alice -x Windscribe")

        # The CLI finds the engine at $XDG_RUNTIME_DIR/windscribe-localipc.sock
        # (ipc/server.cpp), so both sides need the same runtime dir -- a logind
        # session provides it, `su -c` does not.
        status = machine.succeed(
            "su alice -c 'XDG_RUNTIME_DIR=/run/user/1000 windscribe-cli status' 2>&1"
        )
        print(status)
        assert "did not start in time" not in status, status
        assert "helper" not in status.lower(), status

        print(machine.succeed("tail -n 30 /var/log/windscribe/helper.log || true"))
        print(machine.succeed("journalctl -u ws-engine --no-pager | tail -n 30 || true"))
  '';
}
