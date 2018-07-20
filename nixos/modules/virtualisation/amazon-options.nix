{ config, lib, ... }:
{
  options = {
    ec2 = {
      hvm = lib.mkOption {
        default = lib.versionAtLeast config.system.nixos.stateVersion "17.03";
        internal = true;
        description = ''
          Whether the EC2 instance is a HVM instance.
        '';
      };
    };
  };
}
