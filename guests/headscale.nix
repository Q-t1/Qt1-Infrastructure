{
  serverUrl,
  baseDomain,
  internalPort,
  adminSshKeys,
  magicDnsAliases,
  grpcFromHost,
  grpcPort,
  headplane ? { },
}:

{
  config,
  lib,
  pkgs,
  ...
}:

let
  extraRecordsFile = "/var/lib/headscale/extra-records.json";
  hasAliases = magicDnsAliases != { };
  hasHeadplane = headplane != { };
  inherit (import ../lib.nix { inherit lib; }) publicResolvers;
in

{
  microvm = {
    vcpu = 2;
    mem = if hasHeadplane then 1024 else 512;
    volumes = [
      {
        image = "headscale-data.img";
        mountPoint = "/var/lib/headscale";
        size = 512;
      }
    ]
    ++ lib.optional hasHeadplane {
      image = "headplane-data.img";
      mountPoint = config.services.headplane.settings.server.data_path;
      size = 64;
    };
  };

  networking.firewall.allowedTCPPorts = [ internalPort ];
  qt1.guest.allowedTCPPortsFrom = [
    {
      port = 22;
      from = config.qt1.guest.gateway;
    }
  ]
  ++ lib.optional grpcFromHost {
    port = grpcPort;
    from = config.qt1.guest.gateway;
  }
  ++ lib.optional hasHeadplane {
    inherit (headplane) port from;
  };

  services.openssh = {
    enable = true;
    # tmpfs root: use the host-pinned key so it doesn't change on every restart.
    hostKeys = lib.mkForce [ ];
    extraConfig = ''
      HostKey /run/credentials/sshd.service/ssh-host-ed25519-key
    '';
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };
  services.openssh.authorizedKeysFiles = [ "/run/credentials/sshd.service/automation-ssh-pubkey" ];
  systemd.services.sshd.serviceConfig.ImportCredential = [
    "ssh-host-ed25519-key"
    "automation-ssh-pubkey"
  ];
  users.users.root.openssh.authorizedKeys.keys = adminSshKeys;

  services.headscale = {
    enable = true;
    address = "0.0.0.0";
    port = internalPort;
    settings = {
      server_url = serverUrl;
      # headscale only serves remote gRPC with a certificate or
      # grpc_allow_insecure; leaving both unset keeps it on the unix socket.
      grpc_listen_addr = lib.mkIf grpcFromHost "0.0.0.0:${toString grpcPort}";
      grpc_allow_insecure = lib.mkIf grpcFromHost true;
      dns = {
        magic_dns = true;
        base_domain = baseDomain;
        extra_records_path = lib.mkIf hasAliases extraRecordsFile;
        # MagicDNS clients use this as their sole resolver.
        nameservers.global = publicResolvers;
      };
    };
  };

  services.headplane = lib.mkIf hasHeadplane {
    enable = true;
    settings = {
      server = {
        host = "0.0.0.0";
        inherit (headplane) port;
        base_url = headplane.baseUrl;
        cookie_secret_path = "/run/credentials/headplane.service/headplane-cookie-secret";
      };
      # dns_records_path stays unset: headscale-magicdns-aliases owns that file.
    };
  };
  systemd.services.headplane.serviceConfig.ImportCredential = lib.mkIf hasHeadplane [
    "headplane-cookie-secret"
  ];

  # headscale refuses to start if extra_records_path doesn't exist yet.
  systemd.services.headscale.serviceConfig.ExecStartPre = lib.mkIf hasAliases [
    "${pkgs.writeShellScript "headscale-seed-extra-records" ''
      [ -e ${extraRecordsFile} ] || echo '[]' > ${extraRecordsFile}
    ''}"
  ];
  systemd.services.headscale-magicdns-aliases = lib.mkIf hasAliases {
    description = "Point headscale's MagicDNS alias records at their nodes' current addresses";
    after = [ "headscale.service" ];
    requires = [ "headscale.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [
      config.services.headscale.package
      pkgs.jq
      pkgs.diffutils
    ];
    serviceConfig = {
      Type = "oneshot";
      User = config.services.headscale.user;
      Group = config.services.headscale.group;
      Restart = "on-failure";
      RestartSec = "10s";
    };
    script = ''
      set -euo pipefail

      new=$(mktemp)
      trap 'rm -f "$new"' EXIT

      headscale nodes list -o json \
        | jq --argjson aliases ${lib.escapeShellArg (builtins.toJSON magicDnsAliases)} '
            (. // []) as $nodes
            | [ $aliases | to_entries[] as $a
                | $nodes[] | select(.given_name == $a.value)
                | .ip_addresses[]
                | { name: $a.key, type: (if contains(":") then "AAAA" else "A" end), value: . } ]
          ' > "$new"

      # Rewritten in place, and only on change: headscale watches this exact file.
      if ! cmp -s "$new" ${extraRecordsFile}; then
        cat "$new" > ${extraRecordsFile}
      fi
    '';
  };
  systemd.timers.headscale-magicdns-aliases = lib.mkIf hasAliases {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "1min";
    };
  };
}
