# Home Manager module for the Windscribe client.
#
# This installs the client into one user's profile and, optionally, starts the
# engine with their session. It cannot do the privileged half of the job: the
# helper daemon, the setgid wrapper and the windscribe user and group all live
# in the system configuration, so pair this with the NixOS module. Without it
# the engine has no helper socket to talk to and will not connect.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.windscribe;
in
{
  options.programs.windscribe = {
    enable = lib.mkEnableOption "the Windscribe VPN client for this user";

    variant = lib.mkOption {
      type = lib.types.enum [
        "gui"
        "cli"
      ];
      default = "gui";
      description = "Which upstream build to install; see services.windscribe.variant.";
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
      description = "Start the Windscribe engine with this user's graphical session.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];

    systemd.user.services.windscribe = lib.mkIf cfg.autoStart {
      Unit = {
        Description = "Windscribe VPN engine";
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
      };
      Service = {
        # Goes through the package shim, which execs the system setgid wrapper.
        ExecStart = "${cfg.package}/bin/windscribe";
        Restart = "on-failure";
        RestartSec = 5;
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
  };
}
