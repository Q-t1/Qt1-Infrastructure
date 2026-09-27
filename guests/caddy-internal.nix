# caddy-internal: the tailnet-only counterpart of the WAN-facing caddy guest
# (./caddy.nix). One reverse proxy in front of every internal app, each
# served at its own MagicDNS name (<label>.<baseDomain>, e.g.
# grafana.ts.example.com) — the apps themselves never join the tailnet.
#
# Kept apart from ./caddy.nix on purpose: that one is port-forwarded from the
# WAN, this one never is, so no vhost mistake here can publish an internal
# app to the internet, and a compromise of the WAN-facing proxy doesn't hand
# over a tailnet node.
#
# How the names resolve: this guest joins the tailnet as a stable node named
# after the VM (qt1.guest.tailnet in ./base.nix), and headscale serves every <label>.<baseDomain> as an extra
# DNS record pointing at this node's tailnet addresses — kept in sync by
# headscale-magicdns-aliases inside the headscale guest (see
# ./headscale.nix), since those addresses are assigned by headscale at
# registration, not known at build time.
#
# Reachability: caddy listens on port 80, opened only on tailscale0 — not the
# guest bridge, not (transitively) the WAN, since this guest never appears in
# the host's networking.nat.forwardPorts. Requests for anything but a
# declared vhost (this node's own MagicDNS name, its tailnet IP, …) get the
# connection closed. Upstreams are reached over the guest bridge; each app's
# own guest scopes its port to this guest's bridge address.
#
# Plain HTTP: headscale can't issue certificates for MagicDNS names the way
# Tailscale's own `tailscale cert` does, and the tailnet (WireGuard) already
# encrypts the traffic end to end.
#
# Built on ./base.nix; called with the vhosts it serves by the host-side
# module, since guests are evaluated by microvm.nix in a nested nixosSystem
# that gets none of the host's specialArgs.
{
  baseDomain,
  virtualHosts,
}:

{ lib, ... }:

{
  microvm = {
    vcpu = 1;
    mem = 256;
  };
  # "vm-caddy-internal" would exceed the 15-character interface name limit.
  qt1.guest.tapId = "vm-caddy-int";

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 80 ];

  services.caddy = {
    enable = true;
    # Every site below is plain http://; nothing here should ever try ACME.
    globalConfig = ''
      auto_https off
    '';
    virtualHosts = lib.mapAttrs' (
      label: upstream:
      lib.nameValuePair "http://${label}.${baseDomain}" {
        # Access log to the journal instead of the module's default
        # per-vhost file (named after the whole site address, scheme
        # included).
        logFormat = "output stdout";
        extraConfig = ''
          reverse_proxy ${upstream}
        '';
      }
    ) virtualHosts;
    # Catch-all for any Host not declared above — the node's own MagicDNS
    # name, its tailnet IP, anything else: close the connection without a
    # response. Caddy always prefers the more specific site addresses above.
    extraConfig = ''
      http:// {
        abort
      }
    '';
  };
}
