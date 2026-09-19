# NixOS module for the Windscribe VPN client.
#
# Three upstream assumptions have to be met for the client to work at all, and
# each is handled below:
#
#   * The helper refuses to exec any protocol binary unless realpath() of
#     /opt/windscribe is literally /opt/windscribe (src/helper/linux/utils.cpp,
#     resolveExePath). realpath sees through symlinks but not mount points, so
#     the package tree is bind-mounted into the helper's namespace.
#   * The engine must hold the "windscribe" group when it opens the helper
#     socket, then drops it (LinuxUtils::dropHelperGroup). Only a setgid binary
#     can do that, so the engine runs through security.wrappers.
#   * The helper builds its firewall ruleset around getpwnam("windscribe") and
#     fails the whole apply if that user is missing, which takes Stealth and
#     WSTunnel down with it. The user and group are declared here.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.windscribe;

  isGui = cfg.variant == "gui";

  # The helper's PATH is a single hardcoded directory (see [2] in the package),
  # so bin/ and sbin/ of every runtime tool are flattened into one tree that
  # /etc/windscribe/bin points at.
  helperPath = pkgs.runCommand "windscribe-helper-path" { } ''
    mkdir -p $out/bin
    for pkg in ${lib.escapeShellArgs (cfg.package.helperTools ++ cfg.extraHelperPackages)}; do
      for dir in "$pkg/bin" "$pkg/sbin"; do
        [ -d "$dir" ] || continue
        for exe in "$dir"/*; do
          name=$(basename "$exe")
          [ -e "$out/bin/$name" ] || ln -s "$exe" "$out/bin/$name"
        done
      done
    done
  '';
in
{
  options.services.windscribe = {
    enable = lib.mkEnableOption "the Windscribe VPN client and its helper daemon";

    variant = lib.mkOption {
      type = lib.types.enum [
        "gui"
        "cli"
      ];
      default = "gui";
      description = ''
        Which upstream build to install. `gui` is the Qt desktop client, which
        also ships the command line tool. `cli` is the headless engine for
        machines with no display; it is a smaller closure and reports itself to
        Windscribe as a CLI install.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../pkgs/windscribe { inherit (cfg) variant; };
      defaultText = lib.literalExpression "pkgs.callPackage ../pkgs/windscribe { }";
      description = "The Windscribe package to install.";
    };

    autoStart = lib.mkOption {
      type = lib.types.bool;
      default = false;
      example = true;
      description = ''
        Start the Windscribe engine with the user session. Off by default,
        because whether a VPN client launches itself is your decision rather
        than this module's.

        On the `gui` variant this binds to `graphical-session.target`. On the
        `cli` variant it binds to `default.target`, which on a headless machine
        means the unit only runs while the user has a session; use
        `loginctl enable-linger <user>` to keep it up across logouts.
      '';
    };

    extraHelperPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      example = lib.literalExpression "[ pkgs.dnsmasq ]";
      description = ''
        Extra packages to put on the helper's PATH, on top of the set the
        package declares. The helper runs as root, so anything added here is
        reachable by root-owned VPN scripts.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.package.variant == cfg.variant;
        message = ''
          services.windscribe.package was built for the "${cfg.package.variant}"
          variant but services.windscribe.variant is "${cfg.variant}". The two
          disagree on /etc/windscribe/platform and on which engine is installed;
          set them to match.
        '';
      }
    ];

    warnings =
      lib.optional (isGui && !config.networking.networkmanager.enable) ''
        services.windscribe is enabled without NetworkManager. MAC address
        spoofing, the NetworkManager DNS backend and some network-change
        detection call nmcli and will be unavailable. Connections themselves are
        unaffected.
      ''
      ++ lib.optional (!config.services.resolved.enable && !config.networking.networkmanager.enable) ''
        services.windscribe is enabled but neither systemd-resolved nor
        NetworkManager is running. Windscribe's DNS leak protection then falls
        back to the resolvconf script, so set Preferences -> Connection ->
        DNS Manager to "resolvconf" or enable services.resolved.
      '';

    environment.systemPackages = [ cfg.package ];

    # Both are load-bearing: the group gates the helper socket, and the user is
    # who the helper drops privileges to when it starts stunnel and wstunnel.
    # A missing user makes buildFirewallRules fail and blocks obfuscated
    # protocols entirely.
    users.groups.windscribe = { };
    users.users.windscribe = {
      description = "Windscribe VPN proxy runtime user";
      group = "windscribe";
      isSystemUser = true;
      home = "/var/lib/windscribe";
    };

    # The engine connects to /run/windscribe/helper.sock, which is 0770
    # root:windscribe, while it still carries the group from this wrapper; it
    # drops the group immediately afterwards. A file capability does not work
    # here, because the engine never raises into the group, it only ever drops
    # it, so connect() would return EACCES.
    security.wrappers.windscribe-engine = {
      source = "${cfg.package}/opt/windscribe/Windscribe";
      owner = "root";
      group = "windscribe";
      setgid = true;
    };

    environment.etc = {
      # Read by the engine to report which installer flavour this is.
      "windscribe/platform".source = "${cfg.package}/share/windscribe/platform";
      # The directory the helper binary was rewritten to use as its PATH.
      "windscribe/bin".source = "${helperPath}/bin";
    }
    // lib.optionalAttrs isGui {
      # Where the app looks when you toggle "Launch on startup". It copies this
      # into ~/.config/autostart; services.windscribe.autoStart is the
      # declarative alternative.
      "windscribe/autostart/windscribe.desktop".source =
        "${cfg.package}/share/windscribe/autostart/windscribe.desktop";
    };

    # Mount point for the bind mount below. It stays empty in the host
    # namespace; the package tree is only visible inside the helper's.
    systemd.tmpfiles.settings."10-windscribe"."/opt/windscribe".d = {
      mode = "0755";
      user = "root";
      group = "root";
    };

    systemd.services.windscribe-helper = {
      description = "Windscribe VPN helper daemon";
      documentation = [ "https://github.com/Windscribe/Desktop-App" ];
      # Upstream arms the kill switch before any interface comes up.
      before = [ "network-pre.target" ];
      wants = [ "network-pre.target" ];
      wantedBy = [ "multi-user.target" ];
      # ExecStart is a fixed path, so nothing else would notice a new package.
      restartTriggers = [
        cfg.package
        helperPath
      ];

      serviceConfig = {
        Type = "simple";
        # Must be the bind-mounted path, not the store path: the helper compares
        # realpath("/opt/windscribe") against its compile-time install dir
        # before it will exec openvpn, wstunnel, ctrld or amneziawg-go.
        ExecStart = "/opt/windscribe/helper";
        Restart = "on-failure";
        RestartSec = 5;

        # /run/windscribe holds helper.sock, the OpenVPN management socket and
        # the generated config; the helper chowns it to the windscribe group.
        RuntimeDirectory = "windscribe";
        RuntimeDirectoryMode = "0770";
        # /var/lib/windscribe keeps boot_rules.nft, which is how the kill switch
        # survives a reboot, so it has to be persistent.
        StateDirectory = "windscribe";
        LogsDirectory = "windscribe";

        BindReadOnlyPaths = [ "${cfg.package}/opt/windscribe:/opt/windscribe" ];
      };
    };

    systemd.user.services.windscribe = {
      description = "Windscribe VPN engine";
      serviceConfig = {
        Type = "simple";
        ExecStart = "${cfg.package}/bin/windscribe";
        Restart = "on-failure";
        RestartSec = 5;
      };
    }
    // (
      if isGui then
        {
          after = [ "graphical-session.target" ];
          partOf = [ "graphical-session.target" ];
          wantedBy = lib.optional cfg.autoStart "graphical-session.target";
        }
      else
        {
          after = [ "network.target" ];
          wantedBy = lib.optional cfg.autoStart "default.target";
        }
    );
  };

  meta.maintainers = [ ];
}
