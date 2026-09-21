# Host side of the caddy guest: the VM entry and the WAN port forwarding
# that makes it reachable — caddy is now what needs real inbound ports,
# not headscale (see ../../guests/caddy.nix and modules/guests/headscale.nix).
{
  config,
  lib,
  ...
}:

let
  host = config.qt1.infra.microvmHost;
  headscale = config.qt1.infra.guests.headscale;
  cfg = config.qt1.infra.guests.caddy;
in
{
  options.qt1.infra.guests.caddy = {
    enable = lib.mkEnableOption "the caddy microVM (TLS-terminating reverse proxy in front of headscale)";

    address = lib.mkOption {
      type = lib.types.str;
      default = "10.100.0.3";
      description = "Address of the guest on the guest network.";
    };

    mac = lib.mkOption {
      type = lib.types.str;
      default = "02:00:00:00:00:03";
      description = "MAC of the guest's tap interface; the guest matches on it.";
    };

    letsEncryptEmail = lib.mkOption {
      type = lib.types.str;
      example = "you@example.com";
      description = ''
        Contact address for Let's Encrypt certificate issuance. This is
        caddy's own ACME client now — headscale no longer requests a
        certificate of its own, see qt1.infra.guests.headscale.serverUrl.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = host.enable;
        message = "qt1.infra.guests.caddy requires qt1.infra.microvmHost.enable.";
      }
      {
        assertion = headscale.enable;
        message = "qt1.infra.guests.caddy requires qt1.infra.guests.headscale.enable — it exists to front it.";
      }
    ];

    microvm.vms.caddy.config = {
      imports = [
        (import ../../guests/caddy.nix {
          inherit (cfg) address mac letsEncryptEmail;
          inherit (host) prefixLength;
          gateway = host.hostAddress;
          hostname = headscale.tlsHostname;
          upstream = "${headscale.address}:${toString headscale.internalPort}";
        })
      ];
      # storeOnDisk defaults to true (nothing here shares the host's
      # /nix/store into the guest), which defaults systemSymlink to false —
      # that drops share/microvm/system, which `microvm -l` requires to
      # function at all (it dies under set -e the moment readlink on that
      # path fails, for every guest, silently).
      microvm.systemSymlink = true;
    };

    # Real inbound ports: caddy is now the WAN-facing TLS terminator,
    # headscale itself no longer needs any (see
    # modules/guests/headscale.nix).
    networking.nat.forwardPorts = [
      {
        sourcePort = 80;
        destination = "${cfg.address}:80";
        proto = "tcp";
      }
      {
        sourcePort = 443;
        destination = "${cfg.address}:443";
        proto = "tcp";
      }
    ];
  };
}
