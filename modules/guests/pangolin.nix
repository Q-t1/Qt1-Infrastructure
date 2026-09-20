# Host-side declaration of the pangolin guest: the VM entry and the WAN port
# forwarding that makes it actually reachable — unlike the old Cloudflare
# Tunnel, Pangolin terminates real inbound traffic itself, so this is the one
# guest in the repo that needs the host to forward ports in from the WAN. The
# guest's own configuration is ../../guests/pangolin.nix.
{ config, lib, ... }:

let
  host = config.qt1.infra.microvmHost;
  cfg = config.qt1.infra.guests.pangolin;
in
{
  options.qt1.infra.guests.pangolin = {
    enable = lib.mkEnableOption "the Pangolin server microVM (pangolin + gerbil + traefik)";

    address = lib.mkOption {
      type = lib.types.str;
      default = "10.100.0.4";
      description = "Address of the guest on the guest network.";
    };

    mac = lib.mkOption {
      type = lib.types.str;
      default = "02:00:00:00:00:03";
      description = "MAC of the guest's tap interface; the guest matches on it.";
    };

    dashboardDomain = lib.mkOption {
      type = lib.types.str;
      example = "pangolin.example.com";
      description = ''
        Public hostname the Pangolin dashboard and API are reached at. Needs
        a DNS record pointing at this host's WAN address, and (unlike the old
        cloudflared setup) this host's router/firewall must actually forward
        ports 80/tcp and 443/tcp to it — see forwardPorts below and the
        README.
      '';
    };

    baseDomain = lib.mkOption {
      type = lib.types.str;
      example = "tunnel.example.com";
      description = ''
        Base domain resources are exposed under (e.g. a resource named `app`
        becomes app.''${baseDomain}). Needs a wildcard DNS record
        (`*.''${baseDomain}`) pointing at this host's WAN address. Can safely
        equal dashboardDomain (e.g. both your apex domain) — traefik's
        dashboard router matches that hostname exactly, while resources are
        always a subdomain of baseDomain, so the two never collide.
      '';
    };

    letsEncryptEmail = lib.mkOption {
      type = lib.types.str;
      example = "you@example.com";
      description = "Contact address for Let's Encrypt certificate issuance.";
    };

    internalUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://${cfg.address}:3000";
      readOnly = true;
      description = ''
        Pangolin's own public API, reached directly on the guest bridge
        instead of through traefik/TLS/the public dashboardDomain — for a
        newt site that's already on the bridge (this repo's own newt guest,
        see qt1.infra.guests.newt.configFile), which is otherwise no
        different from any other Pangolin site and authenticates the same
        way. Not reachable off the bridge.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = host.enable;
        message = "qt1.infra.guests.pangolin requires qt1.infra.microvmHost.enable.";
      }
    ];

    microvm.vms.pangolin.config = {
      imports = [
        (import ../../guests/pangolin.nix {
          inherit (cfg)
            address
            mac
            dashboardDomain
            baseDomain
            letsEncryptEmail
            ;
          inherit (host) prefixLength;
          gateway = host.hostAddress;
        })
      ];
    };

    # Cloudflare Tunnel needed no inbound ports at all; Pangolin's gerbil
    # terminates real WireGuard/HTTP(S) traffic from the WAN itself, so it has
    # to actually land on the guest. networking.nat (enabled by
    # qt1.infra.microvmHost) already NATs the guest bridge outbound; this adds
    # the matching inbound DNAT.
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
      {
        sourcePort = 51820;
        destination = "${cfg.address}:51820";
        proto = "udp";
      }
      {
        sourcePort = 21820;
        destination = "${cfg.address}:21820";
        proto = "udp";
      }
    ];
  };
}
