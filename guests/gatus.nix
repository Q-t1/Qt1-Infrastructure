# gatus: the public status page. Checks the other guests' services on a
# timer and serves the results, from nixpkgs' own `services.gatus` module
# (no Docker). See ../modules/guests/gatus.nix for which endpoints it checks
# and why.
#
# Public, unlike every other web UI here: the WAN-facing caddy guest
# (./caddy.nix) serves it at its own hostname with a Let's Encrypt
# certificate. Its port is opened on the bridge to caddy's address, so that
# proxy stays the public's one way in, and to the host's, which pushes the
# microVMs' systemd state to it (the external endpoints); the guest itself
# never appears in the host's networking.nat.forwardPorts.
#
# The checks run from here, over the bridge, so they see what a client
# would: headscale through the public caddy and its real certificate, and
# the tailnet apps through caddy-internal. Both proxies' hostnames are
# pinned to their bridge addresses in /etc/hosts (the `hosts` argument), the
# same shortcut the host's own tailnet join takes to avoid NAT hairpinning.
#
# Check history lives in SQLite on a persistent volume, so the uptime bars
# survive a guest restart.
#
# No SSH, like the caddy guests: its own logs are mirrored to the serial
# console, and `journalctl -u microvm@gatus` on the host is how to read them
# — including the check errors the public page hides.
#
# Built on ./base.nix; called with its endpoints by the host-side module,
# since guests are evaluated by microvm.nix in a nested nixosSystem that gets
# none of the host's specialArgs.
{
  # The WAN-facing caddy's bridge address, the only one let through to the
  # web port.
  proxyAddress,
  # gatus endpoints, in its own format.
  endpoints,
  # gatus external endpoints (results pushed by the host), in its own
  # format. Their token is `''${GATUS_PUSH_TOKEN}`, exported below from the
  # gatus-push-token credential.
  externalEndpoints,
  # `address = [ hostname ... ]`, added to /etc/hosts.
  hosts,
}:

{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Must match ../modules/guests/gatus.nix.
  webPort = 8080;
  stateDir = "/var/lib/gatus";
in
{
  microvm = {
    vcpu = 1;
    mem = 256;
    volumes = [
      {
        image = "gatus-data.img";
        mountPoint = stateDir;
        size = 256;
      }
    ];
  };

  qt1.guest.allowedTCPPortsFrom = [
    {
      port = webPort;
      from = proxyAddress;
    }
    {
      port = webPort;
      from = config.qt1.guest.gateway;
    }
  ];

  networking.hosts = hosts;

  services.gatus = {
    enable = true;
    settings = {
      web.port = webPort;
      storage = {
        type = "sqlite";
        path = "${stateDir}/data.db";
      };
      inherit endpoints;
      external-endpoints = externalEndpoints;
    };
  };

  # Upstream runs gatus with DynamicUser, which keeps its StateDirectory at
  # /var/lib/private/gatus behind a symlink. Here that path is a mount point
  # (the volume above), which systemd can't move into private/, so the unit
  # runs as a plain static user instead — the same trade modules/crowdsec.nix
  # makes for crowdsec. StateDirectory still applies, and chowns the volume's
  # root to that user once it's mounted.
  users.users.gatus = {
    isSystemUser = true;
    group = "gatus";
  };
  users.groups.gatus = { };

  systemd.services.gatus.serviceConfig = {
    DynamicUser = lib.mkForce false;
    # gatus expands environment variables in its config, which is how the
    # push token reaches external-endpoints without landing in the Nix store.
    # Upstream's environmentFile is read by systemd before credentials are
    # set up, so the credential is exported by a wrapper instead.
    ImportCredential = [ "gatus-push-token" ];
    ExecStart = lib.mkForce (
      pkgs.writeShellScript "gatus-start" ''
        GATUS_PUSH_TOKEN=$(< "$CREDENTIALS_DIRECTORY/gatus-push-token")
        export GATUS_PUSH_TOKEN
        exec ${lib.getExe config.services.gatus.package}
      ''
    );
    StandardOutput = "journal+console";
    StandardError = "journal+console";
  };
}
