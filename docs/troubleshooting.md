# Troubleshooting

## The client sits at "app did not start in time"

Two different causes share this message.

**The engine cannot reach the helper.** It opens `/run/windscribe/helper.sock`
while holding the `windscribe` group, and only a setgid binary can do that.
Check the wrapper exists and carries the bit:

```console
$ ls -l /run/wrappers/bin/windscribe-engine
-rwxr-sr-x 1 root windscribe ... /run/wrappers/bin/windscribe-engine
```

If it is missing, `services.windscribe.enable` is not set. If you launched the
binary out of the Nix store directly, use `windscribe` from `$PATH` instead:
the store path is not setgid and never can be.

**The CLI cannot reach the engine.** They rendezvous on
`$XDG_RUNTIME_DIR/windscribe-localipc.sock`, so both have to agree on that
variable. A normal desktop or `ssh` login sets it; `su -c` and `sudo` without
`-i` do not. On a server:

```console
$ XDG_RUNTIME_DIR=/run/user/$(id -u) windscribe-cli status
```

## The engine stops when I log out

systemd tears down the user manager with the last session. Keep it running:

```console
$ loginctl enable-linger yourusername
```

## The network is dead after a crash

The kill switch is a real nftables ruleset and it is meant to survive the app.
Turn it off:

```console
$ windscribe-cli firewall off
```

If the engine will not start at all, drop the table by hand:

```console
$ sudo nft delete table inet windscribe
```

If "firewall on boot" was enabled, the ruleset is replayed from
`/var/lib/windscribe/boot_rules.nft` at every start. Delete that file to stop it
coming back.

## DNS stops resolving while connected

Windscribe writes the VPN's resolvers through whichever backend you select in
Preferences under Connection, DNS Manager. Each one needs its tool present, and
all three are on the helper's PATH already:

| Setting | Needs |
|---|---|
| systemd-resolved | `services.resolved.enable = true` |
| NetworkManager | `networking.networkmanager.enable = true` |
| resolvconf | `networking.resolvconf.enable = true` |

"Auto" picks whichever is running. With none of them, set it to resolvconf and
enable that option.

## Split tunnelling is greyed out or does nothing

It is not supported. Upstream drives it through the cgroup v1 `net_cls`
controller, which modern NixOS does not mount, and the helper's mount namespace
would confine the mount even if you did. Nothing else is affected.

## MAC spoofing and "clear WiFi history" do nothing

Both call `nmcli`. Set `networking.networkmanager.enable = true`, or ignore
them. The module warns about this at rebuild time.

## The in-app update button fails

By design. Upstream's updater installs a downloaded `.deb` with apt, dnf, pacman
or zypper through `pkexec`, none of which apply here, so the script is replaced
with one that says so. Update the flake input and rebuild instead:

```console
$ nix flake update windscribe
$ sudo nixos-rebuild switch
```

## The GUI does not appear under Wayland

Qt is linked statically into the binary and picks its own platform plugin.
Force it if the autodetect is wrong:

```console
$ QT_QPA_PLATFORM=xcb windscribe
```

## Where the logs are

| What | Where |
|---|---|
| Helper daemon | `/var/log/windscribe/helper.log`, and `journalctl -u windscribe-helper` |
| Engine and GUI | `~/.local/share/Windscribe/Windscribe2/` |
| ctrld (Connected DNS) | `/var/log/windscribe/ctrld.log` |

The helper log is JSON, one object per line:

```console
$ sudo jq -r '"\(.tm) \(.lvl) \(.msg)"' /var/log/windscribe/helper.log | tail -40
```

## Connections fail only on some protocols

Check the firewall user exists. The helper builds its ruleset around
`getpwnam("windscribe")` and aborts the whole apply when that lookup fails,
which takes Stealth and WSTunnel down while leaving WireGuard working:

```console
$ getent passwd windscribe
windscribe:x:...
```

The module declares it, so a missing entry means the module is not active.

## A version bump broke something

Run the tests; they assert each NixOS-specific fixup individually, so a failure
names the thing that moved:

```console
$ nix flake check -L
```

The most likely breakage is the helper's hardcoded PATH literal. The package
asserts on it at build time and fails with `helper PATH literal not found --
upstream changed it` if upstream edits that string.
