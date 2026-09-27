# Host side of the caddy guest: the VM entry and the WAN port forwarding
# that makes it reachable — caddy is now what needs real inbound ports,
# not headscale (see ../../guests/caddy.nix and modules/guests/headscale.nix).
{
  config,
  lib,
  ...
}:

let
  infraLib = import ../../lib.nix { inherit lib; };
  headscale = config.qt1.infra.guests.headscale;
  cfg = config.qt1.infra.guests.caddy;
in
{
  options.qt1.infra.guests.caddy =
    infraLib.guestOptions {
      index = 3;
      description = "the caddy microVM (TLS-terminating reverse proxy in front of headscale)";
    }
    // {
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

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (infraLib.mkGuest config {
        name = "caddy";
        inherit cfg;
        module = import ../../guests/caddy.nix {
          inherit (cfg) letsEncryptEmail;
          hostname = headscale.tlsHostname;
          upstream = "${headscale.address}:${toString headscale.internalPort}";
        };
      })

      {
        assertions = [
          {
            assertion = headscale.enable;
            message = "qt1.infra.guests.caddy requires qt1.infra.guests.headscale.enable — it exists to front it.";
          }
        ];

        # The host's own tailnet join reaches headscale through this guest
        # over the bridge (see the README's "Joining the tailnet").
        qt1.infra.tailscaleClient.loginServerAddress = lib.mkDefault cfg.address;

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
      }
    ]
  );
}
