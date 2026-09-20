# The Pangolin server: the WAN-facing entrypoint into the local
# infrastructure, replacing the old Cloudflare Tunnel. Three containers, run
# with docker exactly as upstream's own compose file does (there is no native
# nixpkgs package for any of them):
#
#   - pangolin: the control-plane app (dashboard + API). Sites (newt clients,
#     see ../guests/newt.nix) register with it; resources and their routing
#     are configured through its dashboard/API.
#   - gerbil: the WireGuard gateway sites tunnel through. Needs NET_ADMIN and
#     SYS_MODULE to bring up a WireGuard interface, and owns the ports that
#     are actually reachable from the WAN (see ../modules/guests/pangolin.nix
#     for the host-side port forwarding).
#   - traefik: reverse-proxies resources to their targets and terminates TLS
#     (Let's Encrypt), sharing gerbil's network namespace (network_mode:
#     service:gerbil upstream) since that's where the public ports land.
#
# Stateful, unlike the newt guest: Pangolin's own config/db, gerbil's
# WireGuard key and traefik's Let's Encrypt certificates all live on a
# persistent volume, as does docker's own image/layer storage (so a guest
# restart doesn't mean re-pulling every image).
#
# Called with its network coordinates and public hostnames by the host-side
# module; guests are evaluated by microvm.nix in a nested nixosSystem that
# gets none of the host's specialArgs, so they are passed in explicitly
# rather than read from the enclosing config.
{
  address,
  mac,
  gateway,
  prefixLength,
  dashboardDomain,
  baseDomain,
  letsEncryptEmail,
}:

{ pkgs, ... }:

let
  dataDir = "/var/lib/pangolin";

  # Non-secret: dashboardDomain/baseDomain/letsEncryptEmail are plain module
  # options, not credentials. The one genuinely secret value (server.secret)
  # is deliberately left out — Pangolin reads it from SERVER_SECRET_FILE
  # instead (see pangolin-generate-secret below), which the config schema
  # supports precisely so the secret itself never has to sit in a config
  # file.
  pangolinConfig = pkgs.writeText "pangolin-config.yml" ''
    gerbil:
        start_port: 51820
        base_endpoint: "${dashboardDomain}"

    app:
        dashboard_url: "https://${dashboardDomain}"
        log_level: "info"
        telemetry:
            anonymous_usage: false

    domains:
        domain1:
            base_domain: "${baseDomain}"

    server:
        cors:
            origins: ["https://${dashboardDomain}"]
            methods: ["GET", "POST", "PUT", "DELETE", "PATCH"]
            allowed_headers: ["X-CSRF-Token", "Content-Type"]
            credentials: false

    flags:
        require_email_verification: false
        disable_signup_without_invite: true
        disable_user_create_org: false
        allow_raw_resources: true
  '';

  # Ports mirror dynamic_config.yml's own routing: 3000 is Pangolin's public,
  # authenticated API (what traefik forwards /api/v1 to, and what any newt
  # site — including this repo's own, over the guest bridge — registers
  # against); 3001 is the unauthenticated internal API gerbil polls for its
  # own config and is not meant to be reachable by sites at all.
  traefikConfig = pkgs.writeText "traefik_config.yml" ''
    api:
      insecure: true
      dashboard: true
    providers:
      http:
        endpoint: http://pangolin:3001/api/v1/traefik-config
        pollInterval: 5s
      file:
        filename: /etc/traefik/dynamic_config.yml
    experimental:
      plugins:
        badger:
          moduleName: github.com/fosrl/badger
          version: v1.4.1
    log:
      level: INFO
      format: common
      maxSize: 100
      maxBackups: 3
      maxAge: 3
      compress: true
    certificatesResolvers:
      letsencrypt:
        acme:
          httpChallenge:
            entryPoint: web
          email: "${letsEncryptEmail}"
          storage: /letsencrypt/acme.json
          caServer: https://acme-v02.api.letsencrypt.org/directory
    entryPoints:
      web:
        address: ":80"
      websecure:
        address: ":443"
        transport:
          respondingTimeouts:
            readTimeout: 30m
        http:
          tls:
            certResolver: letsencrypt
          encodedCharacters:
            allowEncodedSlash: true
            allowEncodedQuestionMark: true
    serversTransport:
      insecureSkipVerify: true
    ping:
      entryPoint: web
  '';

  dynamicConfig = pkgs.writeText "dynamic_config.yml" ''
    http:
      middlewares:
        badger:
          plugin:
            badger:
              disableForwardAuth: true
        redirect-to-https:
          redirectScheme:
            scheme: https

      routers:
        main-app-router-redirect:
          rule: "Host(`${dashboardDomain}`)"
          service: next-service
          entryPoints:
            - web
          middlewares:
            - redirect-to-https
            - badger

        next-router:
          rule: "Host(`${dashboardDomain}`) && !PathPrefix(`/api/v1`)"
          service: next-service
          entryPoints:
            - websecure
          middlewares:
            - badger
          tls:
            certResolver: letsencrypt

        api-router:
          rule: "Host(`${dashboardDomain}`) && PathPrefix(`/api/v1`)"
          service: api-service
          entryPoints:
            - websecure
          middlewares:
            - badger
          tls:
            certResolver: letsencrypt

      services:
        next-service:
          loadBalancer:
            servers:
              - url: "http://pangolin:3002"

        api-service:
          loadBalancer:
            servers:
              - url: "http://pangolin:3000"

    tcp:
      serversTransports:
        pp-transport-v1:
          proxyProtocol:
            version: 1
        pp-transport-v2:
          proxyProtocol:
            version: 2
  '';
in
{
  microvm = {
    # credentialFiles is only implemented by the qemu runner.
    hypervisor = "qemu";
    vcpu = 2;
    # Not exactly 2048: https://github.com/microvm-nix/microvm.nix/issues/171
    mem = 3072;
    interfaces = [
      {
        type = "tap";
        id = "vm-pangolin";
        inherit mac;
      }
    ];
    volumes = [
      {
        image = "pangolin-data.img";
        mountPoint = dataDir;
        size = 2048;
      }
      {
        image = "pangolin-docker-data.img";
        mountPoint = "/var/lib/docker";
        size = 8192;
      }
    ];
  };

  boot.initrd.kernelModules = [ "qemu_fw_cfg" ];
  # Loaded by gerbil's container (cap_add: SYS_MODULE) at runtime; declaring
  # it here just means the guest's own kernel actually has it to load.
  boot.kernelModules = [ "wireguard" ];

  networking = {
    useNetworkd = true;
    useDHCP = false;
    nameservers = [
      "1.1.1.1"
      "8.8.8.8"
    ];
    # Belt and suspenders alongside docker's own iptables rules for published
    # ports: docker's DNAT/FORWARD path usually doesn't need this, but the
    # exact interaction depends on the docker-proxy/iptables mode in play, and
    # there's no downside to also allowing it explicitly here.
    firewall = {
      allowedTCPPorts = [
        80
        443
      ];
      allowedUDPPorts = [
        51820
        21820
      ];
    };
  };
  systemd.network.networks."10-uplink" = {
    matchConfig.MACAddress = mac;
    address = [ "${address}/${toString prefixLength}" ];
    gateway = [ gateway ];
  };

  virtualisation.docker.enable = true;

  # server.secret, generated once on this guest's own persistent volume (not
  # passed in from the host — nothing here needs a human, unlike newt's
  # dashboard-issued id/secret). Mounted straight into the container as a
  # file rather than an env var, since SERVER_SECRET_FILE is exactly the
  # docker/swarm-secrets convention Pangolin's config loader supports.
  systemd.services.pangolin-generate-secret = {
    description = "Generate Pangolin's server secret on first boot";
    after = [ "local-fs.target" ];
    before = [ "docker-pangolin.service" ];
    wantedBy = [ "docker-pangolin.service" ];
    path = [ pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail
      if [ ! -e ${dataDir}/secret ]; then
        install -d -m 0755 ${dataDir}
        ( umask 0377; head -c 32 /dev/urandom | base64 | tr -d '\n' > ${dataDir}/secret )
      fi
    '';
  };

  # A dedicated docker network so pangolin and gerbil can resolve each other
  # by container name (http://pangolin:3001, http://gerbil:3004), same as
  # upstream's compose file's own default network.
  systemd.services.docker-network-pangolin = {
    description = "Create the pangolin docker network";
    after = [ "docker.service" ];
    requires = [ "docker.service" ];
    before = [
      "docker-pangolin.service"
      "docker-gerbil.service"
    ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${pkgs.docker}/bin/docker network inspect pangolin >/dev/null 2>&1 || \
        ${pkgs.docker}/bin/docker network create pangolin
    '';
  };

  # There's no SSH into this guest — Pangolin has no local CLI you'd ever
  # need to run against it, administration is entirely through its own
  # dashboard/API — and no other route from the host into it, so mirroring
  # the three containers' output to the serial console is the only way to
  # see them at all: `journalctl -u microvm@pangolin` on the host, same
  # mechanism newt's own service uses. This is the only way to
  # retrieve the one-time initial-setup token on first boot (see README).
  systemd.services.docker-pangolin = {
    requires = [
      "docker-network-pangolin.service"
      "pangolin-generate-secret.service"
    ];
    after = [
      "docker-network-pangolin.service"
      "pangolin-generate-secret.service"
    ];
    serviceConfig = {
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
  };
  systemd.services.docker-gerbil = {
    requires = [
      "docker-network-pangolin.service"
      "docker-pangolin.service"
    ];
    after = [
      "docker-network-pangolin.service"
      "docker-pangolin.service"
    ];
    serviceConfig = {
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
  };
  systemd.services.docker-traefik = {
    requires = [ "docker-gerbil.service" ];
    after = [ "docker-gerbil.service" ];
    serviceConfig = {
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
  };

  virtualisation.oci-containers = {
    backend = "docker";
    containers = {
      pangolin = {
        image = "fosrl/pangolin:latest";
        volumes = [
          "${dataDir}:/app/config"
          "${pangolinConfig}:/app/config/config.yml:ro"
          "${dataDir}/secret:/run/secrets/pangolin-secret:ro"
        ];
        environment = {
          SERVER_SECRET_FILE = "/run/secrets/pangolin-secret";
        };
        extraOptions = [
          "--network=pangolin"
          "--network-alias=pangolin"
        ];
      };

      gerbil = {
        image = "fosrl/gerbil:latest";
        cmd = [
          "--reachableAt=http://gerbil:3004"
          "--generateAndSaveKeyTo=/var/config/key"
          "--remoteConfig=http://pangolin:3001/api/v1/"
        ];
        volumes = [ "${dataDir}:/var/config" ];
        ports = [
          "51820:51820/udp"
          "21820:21820/udp"
          "443:443"
          "80:80"
        ];
        extraOptions = [
          "--network=pangolin"
          "--network-alias=gerbil"
          "--cap-add=NET_ADMIN"
          "--cap-add=SYS_MODULE"
        ];
      };

      traefik = {
        image = "traefik:v3.7";
        cmd = [ "--configFile=/etc/traefik/traefik_config.yml" ];
        volumes = [
          "${dataDir}/letsencrypt:/letsencrypt"
          "${traefikConfig}:/etc/traefik/traefik_config.yml:ro"
          "${dynamicConfig}:/etc/traefik/dynamic_config.yml:ro"
        ];
        # Ports appear on gerbil (network_mode: service:gerbil upstream).
        extraOptions = [ "--network=container:gerbil" ];
      };
    };
  };

  system.stateVersion = "26.05";
}
