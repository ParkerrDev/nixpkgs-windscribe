# Upstream release pins.
#
# Regenerate with ./update.sh — it reads the latest GitHub release, pulls the
# SHA-256 table out of the release notes and rewrites this file.
{
  version = "2.24.13";

  # variant -> nix system -> { debArch, hash }
  #
  # The two .deb flavours are mutually exclusive upstream (they Conflict: each
  # other) and ship different builds of the same file names:
  #
  #   gui  windscribe_<v>_<arch>.deb      48 MB Windscribe  (Qt desktop client)
  #   cli  windscribe-cli_<v>_<arch>.deb  16 MB Windscribe  (headless engine)
  #
  # helper, windscribe-cli and libwsnet.so also differ between the two; the
  # protocol binaries (openvpn, wstunnel, amneziawg, ctrld) are byte-identical.
  variants = {
    gui = {
      x86_64-linux = {
        debArch = "amd64";
        hash = "sha256-eanxf898hY6NKzHM2umrfabjhA+8kKl0AQTLCsvOGZE=";
      };
      aarch64-linux = {
        debArch = "arm64";
        hash = "sha256-pvbcsQ4Uz51bDmdvoE69l3E7/ivf7OFGWB5Psoi8Fls=";
      };
    };
    cli = {
      x86_64-linux = {
        debArch = "amd64";
        hash = "sha256-lrXTxic0L+a13nnQTRlKYUWBlrcv9MzQ2htZp1+AT7A=";
      };
      aarch64-linux = {
        debArch = "arm64";
        hash = "sha256-OM+30iMmK56pCgYztgZggIN+Hteu9VXt9QHRNskruxk=";
      };
    };
  };
}
