# Verification record

Every connection mode was exercised against the live Windscribe network from a
throwaway NixOS virtual machine, on 2026-09-19, with Windscribe 2.24.13 on
NixOS 26.11 (nixpkgs `e554fab`, kernel 6.18.52).

The machine ran `services.windscribe.enable = true` with `variant = "cli"`, and
the engine was started through the module's own systemd user unit. For each
protocol the run connected, read the public address back from an outside service
rather than from Windscribe, checked DNS still resolved, then disconnected.

## Results

| Protocol | Interface | Public address | Kill switch |
|---|---|---|---|
| *(disconnected)* | — | *(home address)* | off |
| WireGuard | `utun420` 100.102.4.242/32 | 38.95.111.199 | on |
| UDP | `tun0` 10.141.64.4/22 | 38.95.111.175 | on |
| TCP | `tun0` 10.141.60.46/22 | 38.95.111.211 | on |
| Stealth | `tun0` 10.141.76.2/22 | 38.95.111.136 | on |
| WSTunnel | `tun0` 10.141.68.36/22 | 38.95.111.250 | on |
| *(after disconnect)* | — | *(home address)* | off |

All five exits were Los Angeles. DNS resolved on every one. Disconnecting
restored the home address and tore the firewall down cleanly.

The helper's own log names the backend it chose each time:

```
"Using wireguard kernel module"
"Starting stunnel"
"Starting wstunnel"
```

## Second run, stock desktop configuration

The first run had the NixOS firewall switched off to keep the picture simple.
It was repeated with the machine shaped like a default desktop install:
`networking.firewall` at its default of enabled, which installs strict
reverse-path filtering (four `rpfilter` rules were live), plus NetworkManager
and systemd-resolved both running.

| Protocol | Interface | Public address | Kill switch rules |
|---|---|---|---|
| *(disconnected)* | — | *(home address)* | — |
| WireGuard | `utun420` 100.102.4.242/32 | 38.95.111.218 | 70 |
| UDP | `tun0` 10.141.40.18/22 | 38.95.111.221 | 61 |
| TCP | `tun0` 10.141.60.10/22 | 38.95.111.220 | 61 |
| Stealth | `tun0` 10.141.68.8/22 | 38.95.111.234 | 61 |
| WSTunnel | `tun0` 10.141.84.70/22 | 38.95.111.190 | 61 |
| *(after disconnect)* | — | *(home address)* | — |

The rule counts are the `accept` and `drop` entries in the `inet windscribe`
table while connected, so the kill switch was populated rather than merely
present. On every protocol systemd-resolved reported the tunnel's resolver,
`10.255.255.1`, attached to the VPN link, which is the
`update-systemd-resolved` script doing its job from the helper's rewritten
PATH. The helper's own log for the run names every backend once:

```
"Using wireguard kernel module"
"Using amneziawg-go"
"Starting stunnel"
"Starting wstunnel"
```

## Userspace WireGuard

WireGuard normally rides the kernel module. The bundled `amneziawg-go` takes
over when that is unavailable, which is also the path every AmneziaWG
obfuscation preset uses, so it was tested separately by blocking the module:

```console
# printf '%s\n' 'install wireguard /run/current-system/sw/bin/false' > /run/modprobe.d/no-wireguard.conf
# rmmod wireguard
# modprobe wireguard
modprobe: ERROR: could not insert 'wireguard': Invalid argument
```

The connection still came up, with the public address changing to 38.95.111.199
and the daemon running out of the bind-mounted tree:

```console
$ pgrep -af amneziawg
2101 /opt/windscribe/windscribeamneziawg -f utun420
```

That process listing is the strongest single check in this record. The helper
refuses to exec anything whose parent directory does not `realpath` to
`/opt/windscribe`, so a running `amneziawg` proves the bind mount is in place;
and Go binaries segfault before `main` if `patchelf` has written an RPATH into
them, so it also proves they were left alone.

## Automated coverage

`nix flake check` builds both variants and runs two NixOS VM tests that assert,
for the GUI and headless builds separately:

- the helper's hardcoded PATH literal was rewritten, and every tool it calls is
  present at the new location
- `realpath("/opt/windscribe")` is `/opt/windscribe` inside the helper's mount
  namespace
- `windscribeopenvpn`, `windscribeamneziawg`, `windscribectrld` and
  `windscribewstunnel` all execute
- the `windscribe` user and group exist, which the firewall apply depends on
- `/etc/windscribe/platform` matches the installed variant
- the helper socket is group-gated: a user outside the group is refused, and the
  same user reaches it through a setgid wrapper
- the engine starts, reports `Helper version "Linux helper"`, and answers the CLI

What the automated tests deliberately do not cover is connecting, because that
needs an account and outbound network. That is what this document is for.
