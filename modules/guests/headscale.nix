# Host side of the headscale + headplane guest: the VM entry, the
# credential for headplane's session cookie secret, and the gate that keeps
# the VM stopped until that secret has been provisioned. The guest's own
# configuration is ../../guests/headscale.nix.
{ config, lib, ... }:

let
  host = config.qt1.infra.microvmHost;
  cfg = config.qt1.infra.guests.headscale;
in
{
  options.qt1.infra.guests.headscale = {
    enable = lib.mkEnableOption "the headscale + headplane microVM";

    address = lib.mkOption {
      type = lib.types.str;
      default = "10.100.0.3";
      description = "Address of the guest on the guest network.";
    };

    mac = lib.mkOption {
      type = lib.types.str;
      default = "02:00:00:00:00:02";
      description = "MAC of the guest's tap interface; the guest matches on it.";
    };

    serverUrl = lib.mkOption {
      type = lib.types.str;
      example = "https://headscale.example.com";
      description = ''
        Public URL Tailscale clients and headplane reach headscale at. Route
        this hostname to http://${cfg.address}:8080 in the cloudflared
        tunnel's dashboard-managed config; nothing here opens a port on the
        host or the WAN.
      '';
    };

    baseDomain = lib.mkOption {
      type = lib.types.str;
      example = "tailnet.example.com";
      description = ''
        Base domain for MagicDNS. Must be a different domain to
        {option}`serverUrl`'s.
      '';
    };

    headplaneUrl = lib.mkOption {
      type = lib.types.str;
      example = "https://headplane.example.com";
      description = ''
        Public URL headplane is reached at. Route this hostname to
        http://${cfg.address}:3000 in the cloudflared tunnel's
        dashboard-managed config.
      '';
    };

    cookieSecretFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/microvms/headscale/headplane-cookie-secret";
      description = ''
        Host path holding headplane's session cookie secret: exactly 32
        characters, provisioned by hand (see README). Read by qemu, which
        runs as the `microvm` user, and passed into the guest as a systemd
        credential so it never lands in the Nix store.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = host.enable;
        message = "qt1.infra.guests.headscale requires qt1.infra.microvmHost.enable.";
      }
    ];

    microvm.vms.headscale.config = {
      imports = [
        (import ../../guests/headscale.nix {
          inherit (cfg)
            address
            mac
            serverUrl
            baseDomain
            headplaneUrl
            ;
          inherit (host) prefixLength;
          gateway = host.hostAddress;
        })
      ];
      microvm.credentialFiles.headplane-cookie-secret = cfg.cookieSecretFile;
    };

    # Keep the VM stopped (skipped, not failed) until the secret exists;
    # start it with `systemctl start microvm@headscale` once provisioned.
    systemd.services."microvm@headscale".unitConfig.ConditionPathExists = cfg.cookieSecretFile;
  };
}
