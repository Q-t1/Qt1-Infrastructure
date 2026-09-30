{
  proxyAddress,
  endpoints,
  externalEndpoints,
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

  # The state dir is a mount point, which DynamicUser can't move into
  # /var/lib/private; run as a static user instead.
  users.users.gatus = {
    isSystemUser = true;
    group = "gatus";
  };
  users.groups.gatus = { };

  systemd.services.gatus.serviceConfig = {
    DynamicUser = lib.mkForce false;
    # gatus expands ${GATUS_PUSH_TOKEN} in its config. environmentFile is read
    # before credentials exist, so a wrapper exports it instead.
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
