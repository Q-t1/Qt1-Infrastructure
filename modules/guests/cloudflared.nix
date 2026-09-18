# Host-side declaration of the cloudflared guest: the VM entry, the token
# credential, and the gate that keeps the VM stopped until that token has been
# provisioned. The guest's own configuration is ../../guests/cloudflared.nix.
{ config, lib, ... }:

let
  host = config.qt1.infra.microvmHost;
  cfg = config.qt1.infra.guests.cloudflared;
in
{
  options.qt1.infra.guests.cloudflared = {
    enable = lib.mkEnableOption "the cloudflared tunnel microVM";

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

    tokenFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/microvms/cloudflared/tunnel-token";
      description = ''
        Host path holding the dashboard-managed tunnel token, provisioned by
        hand (see README). Read by qemu, which runs as the `microvm` user, and
        passed into the guest as a systemd credential so it never lands in the
        Nix store.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = host.enable;
        message = "qt1.infra.guests.cloudflared requires qt1.infra.microvmHost.enable.";
      }
    ];

    microvm.vms.cloudflared.config = {
      imports = [
        (import ../../guests/cloudflared.nix {
          inherit (cfg) address mac;
          inherit (host) prefixLength;
          gateway = host.hostAddress;
        })
      ];
      microvm.credentialFiles.tunnel-token = cfg.tokenFile;
    };

    # Keep the VM stopped (skipped, not failed) until the token exists; start
    # it with `systemctl start microvm@cloudflared` once provisioned.
    systemd.services."microvm@cloudflared".unitConfig.ConditionPathExists = cfg.tokenFile;
  };
}
