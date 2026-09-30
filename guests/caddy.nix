{
  hostname,
  upstream,
  letsEncryptEmail,
  virtualHosts ? { },
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
    80
    443
  ];

  systemd.services.caddy.serviceConfig = {
    StandardOutput = "journal+console";
    StandardError = "journal+console";
  };

  services.caddy = {
    enable = true;
    email = letsEncryptEmail;
    virtualHosts = {
      ${hostname} = {
        # Must be the vhost's own logger. A bare `log` directive uses caddy's
        # default logger, which services.caddy pins at ERROR, so INFO access
        # entries are silently dropped. stdout reaches the host journal, which
        # is what CrowdSec reads.
        logFormat = "output stdout";
        extraConfig = ''
          # Keeps headscale's REST API off the WAN; use the CLI over SSH instead.
          @blocked path /api/*
          respond @blocked 404

          reverse_proxy ${upstream}
        '';
      };
    }
    // lib.mapAttrs (_: siteUpstream: {
      logFormat = "output stdout";
      extraConfig = ''
        reverse_proxy ${siteUpstream}
      '';
    }) virtualHosts;

    # The global `metrics` option is what enables HTTP metrics at all.
    # `per_host` only labels hosts with an explicit matcher, so WAN Host
    # headers can't blow up cardinality. The endpoint gets its own site rather
    # than the admin API, which can rewrite caddy's config. The site address
    # is a Host matcher, not a bind address: the firewall rule scopes it.
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

  qt1.guest.allowedTCPPortsFrom = lib.optional (metrics != { }) {
    inherit (metrics) port from;
  };
}
