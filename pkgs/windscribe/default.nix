# Windscribe VPN client, repackaged from the upstream Debian build.
#
# Why a binary repack rather than a source build: upstream's own build fetches a
# prebuilt libwsnet.so (cmake/fetch_wsnet.cmake), so compiling from source still
# lands a vendored binary, while costing a full Qt + OpenSSL-with-ECH toolchain.
# Since 2.2x upstream links Qt statically, so the repack needs no Qt at all --
# there is not a single libQt6* in the shipped NEEDED set.
#
# The four things that make this actually work on NixOS, each marked [1]..[4]
# below, are: the ctrld UPX unpack, the helper's hardcoded PATH, the FHS paths
# baked into the helper scripts, and the update script that would call apt.
{
  lib,
  stdenv,
  fetchurl,
  callPackage,

  # build-time
  autoPatchelfHook,
  dpkg,
  makeWrapper,
  patchelf,
  python3,
  upx,

  # libraries the shipped binaries link against
  acl,
  brotli,
  dbus,
  fontconfig,
  freetype,
  glib,
  harfbuzz,
  libcap_ng,
  libdrm,
  libglvnd,
  libnl,
  libxkbcommon,
  nftables,
  pcre2,
  systemd,
  wayland,
  zlib,
  zstd,

  # Renamed out of the xorg set in nixpkgs 25.11; the defaults keep older
  # nixpkgs working, and are never evaluated on newer ones.
  xorg,
  libx11 ? xorg.libX11,
  libxcb ? xorg.libxcb,
  libxcb-cursor ? xorg.xcbutilcursor,
  libxcb-image ? xorg.xcbutilimage,
  libxcb-keysyms ? xorg.xcbutilkeysyms,
  libxcb-render-util ? xorg.xcbutilrenderutil,
  libxcb-util ? xorg.xcbutil,
  libxcb-wm ? xorg.xcbutilwm,

  # tools the helper and its scripts shell out to at runtime
  bash,
  coreutils,
  ethtool,
  findutils,
  gawk,
  gnugrep,
  gnused,
  iproute2,
  iw,
  kmod,
  nettools,
  networkmanager,
  openresolv,
  procps,
  psmisc,
  util-linux,
  which,
  wireguard-tools,

  # "gui" -> full Qt desktop client; "cli" -> headless engine + CLI only
  variant ? "gui",
  # nmcli drives MAC spoofing, network detection and the NetworkManager DNS
  # backend. Upstream degrades gracefully without it, so servers can drop it.
  withNetworkManager ? true,
}:

let
  sources = import ./sources.nix;
  inherit (sources) version;

  variantInfo =
    sources.variants.${variant}
      or (throw "windscribe: unknown variant ${variant}, expected \"gui\" or \"cli\"");

  source =
    variantInfo.${stdenv.hostPlatform.system}
      or (throw "windscribe: unsupported system ${stdenv.hostPlatform.system}");

  isGui = variant == "gui";
  debName = if isGui then "windscribe" else "windscribe-cli";

  # Written to /etc/windscribe/platform by the NixOS module. The engine reports
  # it to the update API; the CLI build uses a distinct value upstream.
  platform = "linux_deb_x64" + lib.optionalString (!isGui) "_cli";

  # [2] The helper hardcodes its own PATH, so this list has to be reachable from
  # one directory. See the substitution in postPatch and the NixOS module, which
  # symlinks helperPathDir to a buildEnv of exactly these packages.
  helperTools = [
    bash
    coreutils
    ethtool
    findutils
    gawk
    gnugrep
    gnused
    iproute2
    iw
    kmod # modprobe wireguard
    nettools
    openresolv # resolvconf, for the resolv.conf DNS backend
    procps # pkill/pgrep, used to reap openvpn/wstunnel/ctrld
    psmisc
    systemd # busctl/resolvectl/systemctl, for the systemd-resolved DNS backend
    nftables
    util-linux
    which
    wireguard-tools
  ]
  ++ lib.optional withNetworkManager networkmanager;

  # Go executables. autoPatchelfHook has to be kept away from these; see the
  # preFixup note.
  goBinaries = [
    "windscribeamneziawg"
    "windscribectrld"
    "windscribewstunnel"
  ];

  # Absolute path the helper binary is rewritten to use as its PATH. Must be
  # no longer than the string it replaces (29 bytes) -- see [2].
  helperPathDir = "/etc/windscribe/bin";

  runtimePath = lib.makeBinPath helperTools;
in
stdenv.mkDerivation (finalAttrs: {
  pname = if isGui then "windscribe" else "windscribe-cli";
  inherit version;

  src = fetchurl {
    url = "https://github.com/Windscribe/Desktop-App/releases/download/v${version}/${debName}_${version}_${source.debArch}.deb";
    inherit (source) hash;
  };

  nativeBuildInputs = [
    autoPatchelfHook
    dpkg
    makeWrapper
    patchelf
    python3
    upx
  ];

  buildInputs = [
    acl
    brotli
    fontconfig
    freetype
    glib
    harfbuzz
    libcap_ng
    libdrm
    libglvnd
    libnl
    libxkbcommon
    nftables # libnftables.so.1, the helper's firewall backend since 2.24
    pcre2
    (lib.getLib systemd) # libudev
    wayland
    zlib
    zstd
    stdenv.cc.cc.lib
  ]
  ++ lib.optionals isGui [
    libx11
    libxcb
    libxcb-cursor
    libxcb-image
    libxcb-keysyms
    libxcb-render-util
    libxcb-util
    libxcb-wm
  ];

  # Qt reaches libdbus-1 and the GL stack through dlopen, which
  # autoPatchelfHook cannot see in the NEEDED list.
  runtimeDependencies = [ (lib.getLib dbus) ] ++ lib.optional isGui libglvnd;

  sourceRoot = ".";

  unpackPhase = ''
    runHook preUnpack
    dpkg-deb -x $src .
    runHook postUnpack
  '';

  postPatch = ''
    # [1] windscribectrld is a UPX self-extracting binary: it keeps a PT_INTERP
    # but has no section headers, so patchelf refuses it ("probably a statically
    # linked, self-decompressing binary") and autoPatchelfHook leaves it with
    # /lib64/ld-linux-x86-64.so.2, which does not exist here. Unpacking restores
    # a normal ELF that patches cleanly, which is what makes Connected DNS work
    # without pulling in nix-ld.
    if upx -t opt/windscribe/windscribectrld >/dev/null 2>&1; then
      upx -d -q opt/windscribe/windscribectrld
    fi

    # [2] src/helper/linux/main.cpp starts with an unconditional
    #   setenv("PATH", "/usr/sbin:/usr/bin:/sbin:/bin", 1)
    # that overrides whatever systemd puts in the unit environment, so ip,
    # nmcli, modprobe, pkill, resolvectl and systemctl are all unreachable on
    # NixOS. The literal is replaced in place (NUL-padded, never lengthened) so
    # the helper and everything it spawns search a directory we control.
    python3 - opt/windscribe/helper <<'PY'
    import sys

    path = sys.argv[1]
    old = b"/usr/sbin:/usr/bin:/sbin:/bin\x00"
    new = b"${helperPathDir}".ljust(len(old), b"\x00")
    assert len(new) == len(old), "replacement PATH is longer than the original"

    with open(path, "rb") as fh:
        data = fh.read()
    count = data.count(old)
    assert count >= 1, "helper PATH literal not found -- upstream changed it"
    with open(path, "wb") as fh:
        fh.write(data.replace(old, new))
    print(f"patched {count} PATH literal(s) -> ${helperPathDir}")
    PY

    # [3] The helper scripts are plain bash and assume an FHS PATH. They run as
    # root from the helper, so they get the same directory the helper does
    # rather than inheriting whatever called them.
    for script in opt/windscribe/scripts/*; do
      [ -f "$script" ] || continue
      head -n 1 "$script" | grep -q '^#!' || continue
      sed -i "2i export PATH=\"${helperPathDir}:\$PATH\"" "$script"
    done
    patchShebangs opt/windscribe/scripts

    # [4] install-update drives apt/dnf/pacman/zypper through pkexec to install
    # a downloaded .deb over the running one. There is nothing sane for it to do
    # on NixOS, and leaving it in place means an in-app "Update" click runs a
    # package manager that is not there.
    cat > opt/windscribe/scripts/install-update <<'EOF'
    #!${bash}/bin/bash
    echo "Windscribe was installed with Nix; in-app updates are disabled." >&2
    echo "Update the nixpkgs-windscribe flake input and rebuild instead." >&2
    exit 1
    EOF
    chmod +x opt/windscribe/scripts/install-update
  '';

  dontBuild = true;
  # Vendor binaries; stripping buys nothing and can break the Go ones.
  dontStrip = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/opt $out/bin $out/share/windscribe
    cp -r opt/windscribe $out/opt/

    # The engine reads this to decide which installer flavour it is running as.
    # The module installs it at /etc/windscribe/platform; keep a copy so the
    # module never has to restate the value.
    echo -n "${platform}" > $out/share/windscribe/platform

    ${lib.optionalString isGui ''
      # Desktop entry and icons. Exec has to reach the setgid wrapper, so it
      # points at our $out/bin/windscribe shim rather than the raw binary.
      install -Dm644 usr/share/applications/windscribe.desktop \
        $out/share/applications/windscribe.desktop
      substituteInPlace $out/share/applications/windscribe.desktop \
        --replace-fail "/opt/windscribe/Windscribe" "$out/bin/windscribe"

      cp -r usr/share/icons $out/share/

      # Read by the app for its "Launch on startup" toggle: it copies this file
      # into ~/.config/autostart. The module exposes it at the path the app
      # looks in, /etc/windscribe/autostart/.
      install -Dm644 etc/windscribe/autostart/windscribe.desktop \
        $out/share/windscribe/autostart/windscribe.desktop
      substituteInPlace $out/share/windscribe/autostart/windscribe.desktop \
        --replace-fail "/opt/windscribe/Windscribe" "$out/bin/windscribe"
    ''}

    runHook postInstall
  '';

  # libcrypto.so.4 / libssl.so.4 (OpenSSL 4 with ECH) and libwsnet.so ship
  # inside the package and exist nowhere in nixpkgs.
  preFixup = ''
    addAutoPatchelfSearchPath $out/opt/windscribe/lib

    # [5] autoPatchelfHook writes an RPATH into every ELF it finds. Doing that
    # to a Go executable moves its program headers and the Go runtime then dies
    # with SIGSEGV before main -- wstunnel, amneziawg-go and ctrld all segfault
    # on --version. They link nothing but libc, so the interpreter is the only
    # thing they need. Stash them now and put them back after autoPatchelf has
    # run: our postFixup attribute would be too early, because runHook calls the
    # attribute before the postFixupHooks array autoPatchelfHook registered.
    mkdir -p "$NIX_BUILD_TOP/go-pristine"
    for bin in ${lib.escapeShellArgs goBinaries}; do
      cp "$out/opt/windscribe/$bin" "$NIX_BUILD_TOP/go-pristine/$bin"
    done

    restoreGoBinaries() {
      for bin in ${lib.escapeShellArgs goBinaries}; do
        install -Dm755 "$NIX_BUILD_TOP/go-pristine/$bin" "$out/opt/windscribe/$bin"
        patchelf --set-interpreter "$(cat "$NIX_CC/nix-support/dynamic-linker")" \
          "$out/opt/windscribe/$bin"
      done
    }
    postFixupHooks+=(restoreGoBinaries)
  '';

  # The engine has to hold the "windscribe" group when it opens the helper
  # socket, which only a setgid binary can do (upstream's postinst does
  # `chgrp windscribe … && chmod 2755`). A store path cannot be setgid, so the
  # NixOS module builds the wrapper and this shim execs it, after putting the
  # runtime tools on PATH for the engine's own child processes.
  postFixup = ''
    cat > $out/bin/windscribe <<EOF
    #!${bash}/bin/bash
    export PATH="${runtimePath}\''${PATH:+:\$PATH}"
    if [ -x /run/wrappers/bin/windscribe-engine ]; then
      exec /run/wrappers/bin/windscribe-engine "\$@"
    fi
    echo "windscribe: /run/wrappers/bin/windscribe-engine is missing." >&2
    echo "Enable services.windscribe in your NixOS configuration; without the" >&2
    echo "setgid wrapper the engine cannot reach the helper socket." >&2
    exec "$out/opt/windscribe/Windscribe" "\$@"
    EOF
    chmod +x $out/bin/windscribe

    # The CLI only talks to the engine over its own IPC socket, never to the
    # helper, so it needs no elevated group -- matching upstream, which symlinks
    # it into /usr/bin untouched.
    makeWrapper $out/opt/windscribe/windscribe-cli $out/bin/windscribe-cli \
      --prefix PATH : "${runtimePath}"
  '';

  passthru = {
    inherit
      helperTools
      helperPathDir
      platform
      variant
      ;
    updateScript = ./update.sh;
  }
  // lib.optionalAttrs isGui {
    cli = callPackage ./default.nix { variant = "cli"; };
  };

  meta = {
    description =
      "Windscribe VPN client"
      + (if isGui then " (desktop GUI and CLI)" else " (headless engine and CLI)");
    longDescription = ''
      Windscribe desktop client repackaged from upstream's Debian build, with
      the helper daemon, firewall, DNS integration and every connection mode
      wired up for NixOS: WireGuard (kernel module or AmneziaWG userspace),
      OpenVPN over UDP and TCP, Stealth (stunnel) and WSTunnel.
    '';
    homepage = "https://windscribe.com";
    downloadPage = "https://github.com/Windscribe/Desktop-App/releases";
    changelog = "https://github.com/Windscribe/Desktop-App/releases/tag/v${version}";
    license = lib.licenses.gpl2Only;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = lib.attrNames variantInfo;
    mainProgram = if isGui then "windscribe" else "windscribe-cli";
  };
})
