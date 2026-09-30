# Host side of the gatus guest: the VM entry, its public vhost on the
# WAN-facing caddy, and the endpoints it checks — derived from the other
# guests' own options, so a service added elsewhere in this repo shows up on
# the status page without being listed twice. See ../../guests/gatus.nix for
# the guest's own configuration.
{ config, lib, ... }:

let
  infraLib = import ../../lib.nix { inherit lib; };
  headscale = config.qt1.infra.guests.headscale;
  caddy = config.qt1.infra.guests.caddy;
  caddyInternal = config.qt1.infra.guests.caddyInternal;
  cfg = config.qt1.infra.guests.gatus;

  # Must match guests/gatus.nix.
  webPort = 8080;

  # The status page is public, so nothing on it names an internal address,
  # port or hostname — only each endpoint's name, its conditions and whether
  # they held. Errors go too: a failed check's error reads
  # `dial tcp 10.100.0.5:443: ...`. Read them in `journalctl -u
  # microvm@gatus` on the host instead.
  hideInternals = {
    hide-hostname = true;
    hide-url = true;
    hide-port = true;
    hide-errors = true;
  };

  # headscale through the WAN-facing caddy: the same TLS certificate and
  # proxy every Tailscale client goes through. /health answers 200 when
  # headscale can reach its own database, 500 otherwise. The hostname
  # resolves to caddy's bridge address inside the guest (see
  # guests/gatus.nix), not out through the WAN and back in.
  headscaleEndpoint = {
    name = "Headscale";
    group = "Public";
    url = "https://${headscale.tlsHostname}/health";
    interval = "1m";
    conditions = [
      "[STATUS] == 200"
      "[BODY].status == pass"
      # Caddy renews once a third of the lifetime is left (a month, for
      # today's 90-day certificates), so a week left means renewal has been
      # failing for weeks.
      "[CERTIFICATE_EXPIRATION] > 168h"
    ];
    ui = hideInternals;
  };

  # Every app on caddy-internal, at the URL a tailnet client uses, but reached
  # over the bridge: the names resolve to caddy-internal's bridge address
  # inside the guest, and caddy-internal opens 443 to this guest for it
  # (probesFromGatus). That checks proxy and app together, the way a
  # browser sees them.
  #
  # Certificate verification is off for these: they are issued by
  # caddy-internal's own local CA, generated at runtime, which this guest has
  # no copy of. The hop is one bridge hop, and what's checked is
  # reachability, not identity.
  tailnetEndpoints = lib.mapAttrsToList (label: url: {
    name = label;
    group = "Tailnet";
    inherit url;
    interval = "1m";
    client.insecure = true;
    # Redirects are followed (Grafana's `/` sends you to /login), so this is
    # the status of the page a browser would land on. A 502 here is caddy
    # saying the app behind it is down.
    conditions = [ "[STATUS] < 400" ];
    ui = hideInternals;
  }) (lib.optionalAttrs caddyInternal.enable caddyInternal.urls);
in
{
  options.qt1.infra.guests.gatus =
    infraLib.guestOptions {
      index = 6;
      description = "the gatus microVM (public status page, served by the WAN-facing caddy)";
    }
    // {
      hostname = lib.mkOption {
        type = lib.types.str;
        example = "status.example.com";
        description = ''
          Public hostname the status page is served at, by the WAN-facing
          caddy guest (qt1.infra.guests.caddy), with a Let's Encrypt
          certificate of its own. Needs a DNS record pointing at this host's
          WAN address, the same as headscale's serverUrl.
        '';
      };

      url = lib.mkOption {
        type = lib.types.str;
        default = "https://${cfg.hostname}/";
        readOnly = true;
        description = "Where the status page answers, publicly.";
      };

      endpoints = lib.mkOption {
        type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
        default = [ ];
        example = [
          {
            name = "Blog";
            group = "Public";
            url = "https://blog.example.com/";
            conditions = [ "[STATUS] == 200" ];
          }
        ];
        description = ''
          Extra endpoints to check, in gatus's own format
          (https://gatus.io/docs), on top of the ones this module derives:
          headscale through the public caddy, and every
          qt1.infra.guests.caddyInternal.virtualHosts entry through
          caddy-internal. Everything here is shown on a public page, so set
          `ui.hide-url` and friends on anything internal.
        '';
      };
    };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (infraLib.mkGuest config {
        name = "gatus";
        inherit cfg;
        module = import ../../guests/gatus.nix {
          proxyAddress = caddy.address;
          endpoints = [ headscaleEndpoint ] ++ tailnetEndpoints ++ cfg.endpoints;
          # Names the checks above use that must resolve over the bridge
          # rather than through public DNS.
          hosts = {
            ${caddy.address} = [ headscale.tlsHostname ];
          }
          // lib.optionalAttrs (caddyInternal.enable && caddyInternal.virtualHosts != { }) {
            ${caddyInternal.address} = map (label: "${label}.${headscale.baseDomain}") (
              lib.attrNames caddyInternal.virtualHosts
            );
          };
        };
      })

      {
        assertions = [
          {
            assertion = caddy.enable;
            message = "qt1.infra.guests.gatus requires qt1.infra.guests.caddy.enable — the WAN-facing proxy is the status page's only way in.";
          }
        ];

        qt1.infra.guests.caddy.virtualHosts.${cfg.hostname} = "${cfg.address}:${toString webPort}";

        # Opens caddy-internal's 443 to this guest, for the tailnet checks
        # above. Only does anything when caddy-internal is itself enabled.
        qt1.infra.guests.caddyInternal.probesFromGatus = true;
      }
    ]
  );
}
