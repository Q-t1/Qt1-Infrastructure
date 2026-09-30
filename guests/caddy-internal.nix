{
  baseDomain,
  virtualHosts,
  metrics ? { },
  probeFrom ? null,
}:

{ config, lib, ... }:

let
  nodeName = config.qt1.guest.name;

  # root.key and the intermediate's key sit beside root.crt: only route that one file.
  localCaDir = "${config.services.caddy.dataDir}/.local/share/caddy/pki/authorities/local";
in
{
  microvm = {
    vcpu = 1;
    mem = 256;
    volumes = [
      {
        # Holds the local CA root; losing it means re-trusting a new root on every device.
        image = "caddy-data.img";
        mountPoint = config.services.caddy.dataDir;
        size = 256;
      }
    ];
  };
  # "vm-caddy-internal" would exceed the 15-character interface name limit.
  qt1.guest.tapId = "vm-caddy-int";

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [
    80
    443
  ];

  qt1.guest.allowedTCPPortsFrom =
    lib.optional (metrics != { }) {
      inherit (metrics) port from;
    }
    ++ lib.optional (probeFrom != null) {
      port = 443;
      from = probeFrom;
    };

  systemd.services.caddy.serviceConfig = {
    StandardOutput = "journal+console";
    StandardError = "journal+console";
  };

  services.caddy = {
    enable = true;
    # headscale can't drive DNS-01 for MagicDNS names (/set-dns is 501 as of
    # 0.29.3) and nothing here is WAN-reachable, so caddy's own CA issues
    # every certificate.
    globalConfig = ''
      local_certs
    ''
    + lib.optionalString (metrics != { }) ''
      metrics {
        per_host
      }
    '';
    virtualHosts = lib.mapAttrs' (
      label: vhost:
      lib.nameValuePair "https://${label}.${baseDomain}" {
        logFormat = "output stdout";
        extraConfig =
          lib.optionalString (vhost.path != "/") ''
            redir / ${vhost.path}
          ''
          + ''
            reverse_proxy ${vhost.upstream}
          '';
      }
    ) virtualHosts;
    # - The node's own name serves only the CA root, over plain HTTP: a device
    #   can't verify the CA before trusting it.
    # - Explicit http->https redirects: declaring the catch-all suppresses
    #   caddy's automatic ones.
    # - Catch-all aborts any other Host on :80. On 443 an unknown SNI has no
    #   certificate, so none is needed.
    # - The metrics site's address is a Host matcher, not a bind address: the
    #   firewall rule scopes it.
    extraConfig = ''
      http://${nodeName}.${baseDomain} {
        handle /root.crt {
          root * ${localCaDir}
          file_server
        }
        handle {
          abort
        }
      }

      ${lib.concatMapStrings (label: ''
        http://${label}.${baseDomain} {
          redir https://{host}{uri} permanent
        }
      '') (lib.attrNames virtualHosts)}

      http:// {
        abort
      }
    ''
    + lib.optionalString (metrics != { }) ''
      http://${config.qt1.guest.address}:${toString metrics.port} {
        metrics
      }
    '';
  };
}
