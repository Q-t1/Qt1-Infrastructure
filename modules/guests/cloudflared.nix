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

    tailscale = {
      enable = lib.mkEnableOption "joining this guest to the tailnet coordinated by qt1.infra.guests.headscale";

      authKeyFile = lib.mkOption {
        type = lib.types.str;
        default = config.qt1.infra.guests.headscale.tailscaleAuthKeyFile;
        description = ''
          Host path holding a headscale pre-auth key. Defaults to the same
          reusable key headscale-mint-tailscale-authkey generates (see
          qt1.infra.guests.headscale.tailscaleAuthKeyFile) — no provisioning
          needed unless you want this guest on a different key. Read by qemu
          and passed into the guest as a systemd credential, same as the
          tunnel token.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = host.enable;
        message = "qt1.infra.guests.cloudflared requires qt1.infra.microvmHost.enable.";
      }
      {
        assertion = !cfg.tailscale.enable || config.qt1.infra.guests.headscale.enable;
        message = "qt1.infra.guests.cloudflared.tailscale requires qt1.infra.guests.headscale.enable.";
      }
    ];

    microvm.vms.cloudflared.config = {
      imports = [
        (import ../../guests/cloudflared.nix {
          inherit (cfg) address mac;
          inherit (host) prefixLength;
          gateway = host.hostAddress;
          tailscaleEnable = cfg.tailscale.enable;
          # Bridge-local like headscale itself, so this bypasses Cloudflare
          # Tunnel (and its incompatibility with Tailscale's registration
          # protocol) entirely — see serverUrl's description.
          tailscaleLoginServerUrl = config.qt1.infra.guests.headscale.internalUrl;
        })
      ];
      microvm.credentialFiles = {
        tunnel-token = cfg.tokenFile;
      }
      // lib.optionalAttrs cfg.tailscale.enable { tailscale-authkey = cfg.tailscale.authKeyFile; };
    };

    # Keep the VM stopped (skipped, not failed) until the token exists; start
    # it with `systemctl start microvm@cloudflared` once provisioned.
    systemd.services."microvm@cloudflared" = {
      unitConfig.ConditionPathExists = cfg.tokenFile;
    }
    // lib.optionalAttrs cfg.tailscale.enable {
      # Ordering (not just a Condition, unlike the token above) because the
      # dependency is actually generatable: wait for the key to exist rather
      # than fail outright if it's not there yet the very first time.
      wants = [ "headscale-mint-tailscale-authkey.service" ];
      after = [ "headscale-mint-tailscale-authkey.service" ];
    };
  };
}
