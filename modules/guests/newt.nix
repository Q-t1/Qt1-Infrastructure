# Host-side declaration of the newt guest: the VM entry, its config-file
# credential, and the gate that keeps the VM stopped until that config has
# been provisioned. The guest's own configuration is ../../guests/newt.nix.
{ config, lib, ... }:

let
  host = config.qt1.infra.microvmHost;
  cfg = config.qt1.infra.guests.newt;
in
{
  options.qt1.infra.guests.newt = {
    enable = lib.mkEnableOption "the newt (Pangolin site connector) microVM";

    address = lib.mkOption {
      type = lib.types.str;
      default = "10.100.0.2";
      description = "Address of the guest on the guest network.";
    };

    mac = lib.mkOption {
      type = lib.types.str;
      default = "02:00:00:00:00:01";
      description = "MAC of the guest's tap interface; the guest matches on it.";
    };

    configFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/microvms/newt/newt-config.json";
      description = ''
        Host path holding newt's config file, provisioned by hand (see
        README): a JSON object with `endpoint`, `id` and `secret` — the id
        and secret come from creating a "Newt" site in the Pangolin
        dashboard, and endpoint is where this newt reaches the Pangolin
        server (qt1.infra.guests.pangolin.internalUrl when it's this repo's
        own guest, see README). Read by qemu, which runs as the `microvm`
        user, and passed into the guest as a systemd credential so it never
        lands in the Nix store.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = host.enable;
        message = "qt1.infra.guests.newt requires qt1.infra.microvmHost.enable.";
      }
    ];

    microvm.vms.newt.config = {
      imports = [
        (import ../../guests/newt.nix {
          inherit (cfg) address mac;
          inherit (host) prefixLength;
          gateway = host.hostAddress;
        })
      ];
      microvm.credentialFiles = {
        newt-config = cfg.configFile;
      };
    };

    # Keep the VM stopped (skipped, not failed) until the config exists;
    # start it with `systemctl start microvm@newt` once provisioned.
    systemd.services."microvm@newt".unitConfig.ConditionPathExists = cfg.configFile;
  };
}
