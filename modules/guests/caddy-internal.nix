# Host side of the caddy-internal guest: the VM entry, the vhosts it serves,
# and the MagicDNS alias records headscale publishes for them. See
# ../../guests/caddy-internal.nix for the guest's own configuration.
{ config, lib, ... }:

let
  infraLib = import ../../lib.nix { inherit lib; };
  headscale = config.qt1.infra.guests.headscale;
  cfg = config.qt1.infra.guests.caddyInternal;

  # VM name, and so its tailnet node name (qt1.guest.tailnet in
  # guests/base.nix): what every alias record points at.
  name = "caddy-internal";
in
{
  options.qt1.infra.guests.caddyInternal =
    infraLib.guestOptions {
      index = 5;
      description = "the tailnet-only reverse proxy for internal apps (caddy-internal microVM)";
    }
    // {
      virtualHosts = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = {
          grafana = "10.100.0.4:3000";
        };
        description = ''
          Internal apps to serve, as `label = "upstream-host:port"`. Each is
          reachable over the tailnet only, at `http://<label>.<baseDomain>/`
          (qt1.infra.guests.headscale.baseDomain). Guests set their own entry
          here (see modules/guests/monitoring.nix), and open their port to
          this guest's `address` only.
        '';
      };

      urls = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = lib.mapAttrs (label: _: "http://${label}.${headscale.baseDomain}/") cfg.virtualHosts;
        readOnly = true;
        description = "The URL each virtualHosts entry is served at.";
      };
    };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (infraLib.mkGuest config {
        inherit name cfg;
        module = import ../../guests/caddy-internal.nix {
          inherit (cfg) virtualHosts;
          inherit (headscale) baseDomain;
        };
        tailnet = true;
      })

      {
        assertions = [
          {
            assertion = !(cfg.virtualHosts ? ${name});
            message = "qt1.infra.guests.caddyInternal.virtualHosts must not contain `${name}` — that name is already the proxy node's own MagicDNS record.";
          }
        ];

        qt1.infra.guests.headscale.magicDnsAliases = lib.mapAttrs' (
          label: _: lib.nameValuePair "${label}.${headscale.baseDomain}" name
        ) cfg.virtualHosts;
      }
    ]
  );
}
