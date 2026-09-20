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
# local unix socket, so it has to run on this guest itself. Two keys are
# authorized: adminSshKey for a human, and a host-generated one for
# headscale-mint-tailscale-authkey to run unattended (see
# ../modules/guests/headscale.nix).
#
# Called with its network coordinates and public hostname by the host-side
# module; guests are evaluated by microvm.nix in a nested nixosSystem that
# gets none of the host's specialArgs, so they are passed in explicitly
# rather than read from the enclosing config.
{
  address,
  mac,
  gateway,
  prefixLength,
  serverUrl,
  baseDomain,
  internalPort,
  adminSshKey,
}:

{ lib, ... }:

{
  microvm = {
    # credentialFiles is only implemented by the qemu runner.
    hypervisor = "qemu";
    vcpu = 2;
    mem = 512;
    interfaces = [
      {
        type = "tap";
        id = "vm-headscale";
        inherit mac;
      }
    ];
    volumes = [
      {
        image = "headscale-data.img";
        mountPoint = "/var/lib/headscale";
        size = 512;
      }
    ];
  };

  # Credentials (the SSH host key and the automation pubkey) arrive over
  # qemu's fw_cfg; its sysfs interface is a module, so load it early enough
  # for systemd to import them at boot.
  boot.initrd.kernelModules = [ "qemu_fw_cfg" ];

  networking = {
    useNetworkd = true;
    useDHCP = false;
    nameservers = [
      "1.1.1.1"
      "8.8.8.8"
    ];
    firewall = {
      # Only the plain-HTTP port caddy proxies to — bridge-only, since this
      # guest is never in the host's forwardPorts.
      allowedTCPPorts = [ internalPort ];
      # SSH (admin access, for one-off `headscale` CLI commands) is not in
      # allowedTCPPorts: it must only be reachable from the host, not from
      # other guests on the bridge. extraCommands runs before the
      # firewall's default-drop rule, so this is the only way in on port 22.
      extraCommands = ''
        iptables -A nixos-fw -p tcp --dport 22 -s ${gateway} -j nixos-fw-accept
      '';
    };
  };
  systemd.network.networks."10-uplink" = {
    matchConfig.MACAddress = mac;
    address = [ "${address}/${toString prefixLength}" ];
    gateway = [ gateway ];
  };

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
  # users.users.root.openssh.authorizedKeys.keys below, so root accepts
  # either key: adminSshKey for a human, this credential for
  # headscale-mint-tailscale-authkey running unattended on the host.
  services.openssh.authorizedKeysFiles = [ "/run/credentials/sshd.service/automation-ssh-pubkey" ];
  systemd.services.sshd.serviceConfig.ImportCredential = [
    "ssh-host-ed25519-key"
    "automation-ssh-pubkey"
  ];
  users.users.root.openssh.authorizedKeys.keys = [ adminSshKey ];

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
        base_domain = baseDomain;
        # MagicDNS clients use this as their sole resolver, so it must be
        # able to resolve the public internet too, not just the tailnet.
        nameservers.global = [
          "1.1.1.1"
          "8.8.8.8"
        ];
      };
    };
  };

  system.stateVersion = "26.05";
}
