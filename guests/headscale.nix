# headscale: a self-hosted Tailscale coordination server. Built entirely
# from nixpkgs' own `services.headscale` module — no Docker. Unlike the
# guest this repo ran WAN-facing before it, TLS is no longer headscale's own
# job: the caddy guest (../modules/guests/caddy.nix) terminates it and
# reverse-proxies in, so headscale itself only listens plain HTTP on the
# guest bridge (internalPort below) and is never reachable from the WAN
# directly.
#
# /api/v1/* (headscale's REST API) is bearer-token gated (401 without a
# valid API key), but that's now a second layer, not the only one: caddy's
# own Caddyfile refuses to proxy /api/* at all, so it's not reachable from
# the WAN full stop — no API key is ever provisioned ahead of time either
# way, mint one on demand over SSH when actually needed (`headscale apikeys
# create`). gRPC (`grpc_listen_addr`) stays at its own default of
# 127.0.0.1-only and was never forwarded from the WAN regardless.
#
# Stateful: headscale's own node/key database and its Noise and DERP
# private keys all live under /var/lib/headscale, a persistent volume —
# none of it regenerates across guest restarts.
#
# SSH is enabled for root, key-only, and reachable only from the host (not
# from other guests on the bridge or the WAN) — the `headscale` CLI (e.g.
# `apikeys create`, `preauthkeys create`) talks to the running server over a
# local unix socket, so it has to run on this guest itself. adminSshKeys
# (humans plus the host's own default keys, see
# qt1.infra.microvmHost.adminSshKeys) are authorized alongside a separate,
# host-generated key for headscale-mint-tailscale-authkey to run unattended
# (see ../modules/guests/headscale.nix).
#
# Built on ./base.nix (network coordinates under config.qt1.guest); called
# with its public identity and SSH keys by the host-side module, since guests
# are evaluated by microvm.nix in a nested nixosSystem that gets none of the
# host's specialArgs.
{
  serverUrl,
  baseDomain,
  internalPort,
  adminSshKeys,
  magicDnsAliases,
}:

{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Watched by headscale itself (dns.extra_records_path), which reloads it on
  # every change — no restart needed when an alias's target moves.
  extraRecordsFile = "/var/lib/headscale/extra-records.json";
  hasAliases = magicDnsAliases != { };
  inherit (import ../lib.nix { inherit lib; }) publicResolvers;
in

{
  microvm = {
    vcpu = 2;
    mem = 512;
    volumes = [
      {
        image = "headscale-data.img";
        mountPoint = "/var/lib/headscale";
        size = 512;
      }
    ];
  };

  # Only the plain-HTTP port caddy proxies to — bridge-only, since this
  # guest is never in the host's forwardPorts.
  networking.firewall.allowedTCPPorts = [ internalPort ];
  # SSH (admin access, for one-off `headscale` CLI commands) is not in
  # allowedTCPPorts: it must only be reachable from the host, not from other
  # guests on the bridge.
  qt1.guest.allowedTCPPortsFrom = [
    {
      port = 22;
      from = config.qt1.guest.gateway;
    }
  ];

  services.openssh = {
    enable = true;
    # The root filesystem is tmpfs, so a generated host key would be
    # regenerated (and change) on every VM restart. Use the one pinned by the
    # host instead (see ../modules/guests/headscale.nix), imported the same
    # way as the automation pubkey below.
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
  # authorizedKeysFiles is additive with the default NixOS sets from
  # users.users.root.openssh.authorizedKeys.keys below, so root accepts any
  # of: adminSshKeys, this credential for headscale-mint-tailscale-authkey
  # running unattended on the host.
  services.openssh.authorizedKeysFiles = [ "/run/credentials/sshd.service/automation-ssh-pubkey" ];
  systemd.services.sshd.serviceConfig.ImportCredential = [
    "ssh-host-ed25519-key"
    "automation-ssh-pubkey"
  ];
  users.users.root.openssh.authorizedKeys.keys = adminSshKeys;

  services.headscale = {
    enable = true;
    # Bridge-reachable (from the caddy guest specifically), not the WAN —
    # caddy is what the WAN actually reaches. Plain HTTP: no TLS options
    # here at all now, caddy owns that.
    address = "0.0.0.0";
    port = internalPort;
    settings = {
      # Still the public https:// identity clients are told to use — caddy
      # is just what actually answers for it now. headscale doesn't care
      # that its own listener is plain HTTP as long as server_url matches
      # what's reachable from the outside.
      server_url = serverUrl;
      dns = {
        # The module's default already, pinned since caddy-internal's apps
        # are only served at MagicDNS names (see magicDnsAliases below).
        magic_dns = true;
        base_domain = baseDomain;
        extra_records_path = lib.mkIf hasAliases extraRecordsFile;
        # MagicDNS clients use this as their sole resolver, so it must be
        # able to resolve the public internet too, not just the tailnet.
        nameservers.global = publicResolvers;
      };
    };
  };

  # magicDnsAliases: publish each alias fqdn as A/AAAA records pointing at
  # the named node's current tailnet addresses. headscale refuses to start
  # if extra_records_path doesn't exist yet, so seed it empty first; after
  # that, headscale-magicdns-aliases rewrites it (only when it changes)
  # whenever it runs, and headscale picks the change up by itself.
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
      # Same user as headscale: owns extraRecordsFile, and is in the group
      # allowed on the CLI's unix socket.
      User = config.services.headscale.user;
      Group = config.services.headscale.group;
      # Right after boot headscale's CLI socket may not be up yet.
      Restart = "on-failure";
      RestartSec = "10s";
    };
    script = ''
      set -euo pipefail

      new=$(mktemp)
      trap 'rm -f "$new"' EXIT

      # A node that isn't registered (yet) simply contributes no records.
      headscale nodes list -o json \
        | jq --argjson aliases ${lib.escapeShellArg (builtins.toJSON magicDnsAliases)} '
            (. // []) as $nodes
            | [ $aliases | to_entries[] as $a
                | $nodes[] | select(.given_name == $a.value)
                | .ip_addresses[]
                | { name: $a.key, type: (if contains(":") then "AAAA" else "A" end), value: . } ]
          ' > "$new"

      # Rewritten in place (not renamed over) and only on change: headscale
      # watches this exact file.
      if ! cmp -s "$new" ${extraRecordsFile}; then
        cat "$new" > ${extraRecordsFile}
      fi
    '';
  };
  # Addresses only change when a node re-registers; polling keeps that
  # (and a node joining after headscale started) covered without a hook
  # into headscale itself.
  systemd.timers.headscale-magicdns-aliases = lib.mkIf hasAliases {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "1min";
    };
  };
}
