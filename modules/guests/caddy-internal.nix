# Host side of the caddy-internal guest: the VM entry, the vhosts it serves,
# and the MagicDNS alias records headscale publishes for them. See
# ../../guests/caddy-internal.nix for the guest's own configuration.
{ config, lib, ... }:

let
  host = config.qt1.infra.microvmHost;
  headscale = config.qt1.infra.guests.headscale;
  caddy = config.qt1.infra.guests.caddy;
  cfg = config.qt1.infra.guests.caddyInternal;
in
{
  options.qt1.infra.guests.caddyInternal = {
    enable = lib.mkEnableOption "the tailnet-only reverse proxy for internal apps (caddy-internal microVM)";

    address = lib.mkOption {
      type = lib.types.str;
      default = "10.100.0.5";
      description = ''
        Address of the guest on the guest network — what each upstream's own
        guest should accept its app port from.
      '';
    };

    mac = lib.mkOption {
      type = lib.types.str;
      default = "02:00:00:00:00:05";
      description = "MAC of the guest's tap interface; the guest matches on it.";
    };

    nodeName = lib.mkOption {
      type = lib.types.str;
      default = "caddy-internal";
      description = ''
        Tailnet node name the guest registers under. Every virtualHosts
        entry is published by headscale as an alias record pointing at this
        node's tailnet addresses. The node's own MagicDNS name serves nothing.
      '';
    };

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
        here (see modules/guests/monitoring.nix).
      '';
    };

    urls = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = lib.mapAttrs (label: _: "http://${label}.${headscale.baseDomain}/") cfg.virtualHosts;
      readOnly = true;
      description = "The URL each virtualHosts entry is served at.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = host.enable;
        message = "qt1.infra.guests.caddyInternal requires qt1.infra.microvmHost.enable.";
      }
      {
        assertion = headscale.enable;
        message = "qt1.infra.guests.caddyInternal requires qt1.infra.guests.headscale.enable — it joins the tailnet it coordinates, and headscale publishes its vhosts' names.";
      }
      {
        assertion = caddy.enable;
        message = "qt1.infra.guests.caddyInternal requires qt1.infra.guests.caddy.enable — it needs caddy's bridge address for the NAT-hairpin shortcut its tailscale-autoconnect run uses (see guests/caddy-internal.nix).";
      }
      {
        assertion = !(cfg.virtualHosts ? ${cfg.nodeName});
        message = "qt1.infra.guests.caddyInternal.virtualHosts must not contain the proxy's own nodeName (${cfg.nodeName}) — that name is already the node's own MagicDNS record.";
      }
    ];

    microvm.vms.caddy-internal.config = {
      imports = [
        (import ../../guests/caddy-internal.nix {
          inherit (cfg)
            address
            mac
            nodeName
            virtualHosts
            ;
          inherit (host) prefixLength;
          inherit (headscale) baseDomain tlsHostname;
          gateway = host.hostAddress;
          loginServerUrl = headscale.serverUrl;
          caddyAddress = caddy.address;
        })
      ];
      # storeOnDisk defaults to true, which defaults systemSymlink to false —
      # that drops share/microvm/system, which `microvm -l` requires to
      # function at all. Same reasoning as every other guest here.
      microvm.systemSymlink = true;
      # The same shared, reusable pre-auth key every tailscaleClient consumer
      # points at (see modules/guests/headscale.nix and the README's "Joining
      # the tailnet" section) — not a secret of this guest's own.
      microvm.credentialFiles.tailscale-authkey = headscale.tailscaleAuthKeyFile;
    };

    qt1.infra.guests.headscale.magicDnsAliases = lib.mapAttrs' (
      label: _: lib.nameValuePair "${label}.${headscale.baseDomain}" cfg.nodeName
    ) cfg.virtualHosts;
  };
}
