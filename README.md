<h1 align="center">
  <img src="https://static.windscribe.com/v2/img/WS-Logo-white@2x.png" width="200px" alt="Windscribe" />
  <br>
  nixpkgs-windscribe
</h1>

<p align="center"><em>The Windscribe VPN client, packaged for NixOS. Unofficial.</em></p>

<p align="center">
  <img alt="packaged" src="https://img.shields.io/badge/windscribe-2.24.13-blueviolet" />
  <img alt="protocols" src="https://img.shields.io/badge/protocols-WireGuard%20%7C%20UDP%20%7C%20TCP%20%7C%20Stealth%20%7C%20WSTunnel-brightgreen" />
  <img alt="license" src="https://img.shields.io/badge/packaging-MIT-blue" />
</p>

---

Every connection mode works: WireGuard, OpenVPN over UDP and TCP, Stealth and
WSTunnel. So do the kill switch, DNS leak protection and Connected DNS. The
package ships both the Qt desktop client and a headless build for servers.

This is a repack of upstream's own Debian build rather than a source build.
Upstream's build system downloads a prebuilt `libwsnet.so`, so compiling from
source still lands a vendored binary while costing a full Qt and
OpenSSL-with-ECH toolchain. Since 2.2x upstream links Qt statically, which
means the repack needs no Qt at all.

## Install

Add the flake and turn the module on.

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    windscribe = {
      url = "github:ParkerrDev/nixpkgs-windscribe";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, windscribe, ... }: {
    nixosConfigurations.mymachine = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        windscribe.nixosModules.windscribe
        { services.windscribe.enable = true; }
      ];
    };
  };
}
```

Rebuild, then launch Windscribe from your application menu or run `windscribe`.
The helper daemon starts on boot; you do not need to run anything by hand.

On a headless machine, install the smaller build instead:

```nix
services.windscribe = {
  enable = true;
  variant = "cli";
  autoStart = true;
};
```

Then `loginctl enable-linger <user>` so the engine survives logout, and drive it
with `windscribe-cli login`, `windscribe-cli connect`, `windscribe-cli status`.

Without flakes:

```nix
{
  imports = [
    "${builtins.fetchTarball "https://github.com/ParkerrDev/nixpkgs-windscribe/archive/refs/heads/master.tar.gz"}/modules/nixos.nix"
  ];
  services.windscribe.enable = true;
}
```

## Options

| Option | Type | Default | What it does |
|---|---|---|---|
| `services.windscribe.enable` | bool | `false` | Install the client and run the helper daemon |
| `services.windscribe.variant` | `"gui"` / `"cli"` | `"gui"` | Qt desktop client, or the headless engine |
| `services.windscribe.package` | package | matching variant | Override the package |
| `services.windscribe.autoStart` | bool | `false` | Start the engine with the user session |
| `services.windscribe.extraHelperPackages` | list | `[ ]` | Extra tools on the helper's PATH |

A Home Manager module is exposed as `homeManagerModules.windscribe` for per-user
installs. It cannot replace the NixOS module: the helper daemon, the setgid
wrapper and the `windscribe` system user are privileged and have to be declared
system-wide.

## Protocols

| Mode | Backed by | Verified |
|---|---|---|
| WireGuard | kernel module, falling back to bundled `amneziawg-go` | yes (both paths) |
| UDP | bundled OpenVPN 2.7.5 | yes |
| TCP | bundled OpenVPN 2.7.5 | yes |
| Stealth | OpenVPN wrapped in TLS by the bundled `wstunnel` | yes |
| WSTunnel | bundled Windscribe `wstunnel` | yes |

Each was checked by connecting from a NixOS VM and confirming the public
address changed, DNS still resolved and the kill switch engaged. See
[docs/verification.md](docs/verification.md) for the transcript.

Connected DNS works too, through the bundled `ctrld`. Split tunnelling does
**not**: it needs the cgroup v1 `net_cls` controller, which modern NixOS does
not mount.

## What makes this non-trivial

Upstream's Linux build assumes a filesystem hierarchy NixOS does not have, in
four separate places. Each is dealt with explicitly, and each is covered by an
assertion in the VM tests so a version bump cannot quietly undo it.

**The helper only execs binaries out of `/opt/windscribe`.** Before it starts
OpenVPN, wstunnel, ctrld or amneziawg-go it compares `realpath("/opt/windscribe")`
against its compile-time install directory and refuses anything else. `realpath`
sees through symlinks, so pointing that path at the Nix store does not work. The
module bind-mounts the package tree into the helper's mount namespace instead,
which `realpath` cannot see through.

**The helper hardcodes its own PATH.** `main.cpp` runs
`setenv("PATH", "/usr/sbin:/usr/bin:/sbin:/bin", 1)` before anything can spawn a
child, which overrides whatever systemd puts in the unit environment and leaves
`ip`, `nmcli`, `modprobe`, `pkill` and `resolvectl` unreachable. The package
rewrites that string literal in place, NUL-padded so it is never lengthened, to
point at a directory the module fills with exactly the tools upstream calls.

**The engine needs a group it can only inherit.** It opens the helper socket
while holding the `windscribe` group and drops it immediately afterwards, so a
file capability is no help: the process never raises into the group. The module
installs a setgid wrapper, which is what upstream's `postinst` achieves with
`chgrp windscribe && chmod 2755`.

**Three of the shipped binaries are Go.** `patchelf` writing an RPATH into a Go
executable moves its program headers and the runtime then dies with SIGSEGV
before `main`, so wstunnel, amneziawg-go and ctrld are kept away from
`autoPatchelfHook` and given only an interpreter. `ctrld` needs one extra step:
it is UPX-packed and has no section headers at all, so it is unpacked first.
Skipping that is what forces other packagings to depend on `nix-ld`.

Two smaller ones: the firewall ruleset is built around
`getpwnam("windscribe")` and fails the whole apply when that user is missing,
which takes Stealth and WSTunnel down with it, so the module declares the user;
and `install-update` shells out to apt, dnf, pacman or zypper through `pkexec`,
so it is replaced with a script that tells you to bump the flake.

## Updating

```bash
./pkgs/windscribe/update.sh          # or: ./pkgs/windscribe/update.sh 2.25.0
nix build .#windscribe .#windscribe-cli
nix flake check                      # runs the VM tests
```

The update script fetches each `.deb` and records the hash it actually got,
rather than trusting the table in the release notes.

Do not use the in-app update button. It is wired to a script that refuses,
because on NixOS there is no package manager for it to call.

## Tests

`nix flake check` builds both variants and runs two NixOS VM tests that assert
the helper's PATH was rewritten, `/opt/windscribe` resolves to itself inside the
helper's namespace, every protocol binary runs, the helper socket is group-gated,
a plain user reaches it only through the setgid wrapper, and the engine comes up
and talks to the helper. The VM tests need KVM.

## Troubleshooting

See [docs/troubleshooting.md](docs/troubleshooting.md).

## Credits

[Windscribe](https://github.com/Windscribe/Desktop-App) for the client.
Earlier NixOS attempts by [adrianmgg](https://github.com/adrianmgg),
[syntheit](https://github.com/syntheit/windscribe-nix),
[ItzDerock](https://github.com/ItzDerock/windscribe-nix) and
[Varmisanth](https://github.com/Varmisanth/windscribe-nixos) mapped out the
setgid and bind-mount problems before this repackaging.

Contributions welcome.
