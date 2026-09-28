# caddy: the WAN-facing reverse proxy in front of headscale. Takes over the
# job headscale's own built-in Let's Encrypt did before, but as a real HTTP
# reverse proxy it can also do what a single TLS listener inside headscale
# itself couldn't: keep /api/v1/* (headscale's REST API) off the public
# internet entirely, not just bearer-token gated. See
# ../modules/guests/caddy.nix and headscale's own guest config
# (../guests/headscale.nix).
#
# Its Prometheus metrics (request rates, latency histograms, in-flight
# requests) are served on a port of their own, for the monitoring guest
# alone, and only when it asks for them — see the `metrics` argument below
# and qt1.infra.guests.caddy.metricsFromMonitoring.
#
# Stateful, unlike a "just forwards packets" guest: caddy's certificate and
# ACME account data live on a persistent volume (/var/lib/caddy), so a
# guest restart doesn't mean re-issuing a certificate (and burning into
# Let's Encrypt's rate limit) every time.
#
# No SSH — caddy needs no local CLI/admin access the way headscale does,
# it's entirely declared here. Its own service logs are mirrored to the
# guest's serial console instead, the same reasoning as pangolin's old
# guest: `journalctl -u microvm@caddy` on the host is the only way to see
# them, since there's no other route in.
#
# Built on ./base.nix; called with the hostname/upstream it fronts by the
# host-side module, since guests are evaluated by microvm.nix in a nested
# nixosSystem that gets none of the host's specialArgs.
{
  hostname,
  upstream,
  letsEncryptEmail,
  # `{ port = <n>; from = "<address>"; }` when the monitoring guest scrapes
  # this one (qt1.infra.guests.caddy.metricsFromMonitoring), `{ }` otherwise:
  # it gates the whole metrics listener below, collection included.
  metrics ? { },
}:

{ config, lib, ... }:

{
  microvm = {
    vcpu = 1;
    mem = 256;
    volumes = [
      {
        image = "caddy-data.img";
        mountPoint = "/var/lib/caddy";
        size = 256;
      }
    ];
  };

  networking.firewall.allowedTCPPorts = [
    80 # ACME HTTP-01 challenge, and caddy's own http->https redirect
    443
  ];

  systemd.services.caddy.serviceConfig = {
    StandardOutput = "journal+console";
    StandardError = "journal+console";
  };

  services.caddy = {
    enable = true;
    email = letsEncryptEmail;
    virtualHosts.${hostname}.extraConfig = ''
      # headscale's REST API (/api/v1/*) is bearer-token gated on its own,
      # but that's not the same as being off the public internet — this is
      # what actually keeps it off: never proxied, full stop. Use SSH + the
      # local `headscale` CLI (see the README) for anything that would
      # otherwise need this from outside the bridge.
      @blocked path /api/*
      respond @blocked 404

      reverse_proxy ${upstream}

      # No access log by default in caddy — this is what actually gives
      # qt1.infra.crowdsec (../modules/crowdsec.nix) something to read.
      # Goes to stdout, captured the same way as everything else here (see
      # systemd.services.caddy.serviceConfig below): mirrored to this
      # guest's console, and from there to the host's journal.
      log
    '';

    # Prometheus metrics, when the monitoring guest collects them. Two halves:
    #
    #  - the global `metrics` option, which is what actually turns HTTP metrics
    #    collection on (without it caddy 2.11 leaves them unregistered and the
    #    endpoint below serves only Go/process metrics). `per_host` adds the
    #    vhost as a label; caddy only labels hosts it has an explicit matcher
    #    for and buckets everything else under `_other`, so an arbitrary Host
    #    header off the WAN can't blow up the label cardinality.
    #
    #  - a site of its own for the endpoint, on a port of its own. Caddy
    #    already serves /metrics on its admin API, but that API can also
    #    rewrite caddy's whole configuration, so it stays on the guest's
    #    loopback where upstream put it: this site exposes the metrics and
    #    nothing else. Plain http:// with an explicit port, so automatic HTTPS
    #    leaves it alone (no certificate for a bridge address, and nothing to
    #    redirect).
    #
    #    The address in the site line becomes a Host matcher, not a bind
    #    address — caddy still listens on :<port> on every interface — so what
    #    actually keeps this endpoint to one caller is the firewall rule
    #    below.
    globalConfig = lib.mkIf (metrics != { }) ''
      metrics {
        per_host
      }
    '';
    extraConfig = lib.mkIf (metrics != { }) ''
      http://${config.qt1.guest.address}:${toString metrics.port} {
        metrics
      }
    '';
  };

  # What scopes the metrics listener above: the monitoring guest's address
  # only, not the rest of the bridge, and never the WAN — this port has no
  # forwardPorts entry on the host.
  qt1.guest.allowedTCPPortsFrom = lib.optional (metrics != { }) {
    inherit (metrics) port from;
  };
}
