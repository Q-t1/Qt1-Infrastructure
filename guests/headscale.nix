# headscale: a self-hosted Tailscale coordination server, and now the
# WAN-facing entrypoint into the local infrastructure in its own right (the
# job Pangolin/gerbil/traefik did before it). Built entirely from nixpkgs'
# own `services.headscale` module — no Docker, no separate reverse proxy:
# TLS is headscale's own built-in Let's Encrypt (tls_letsencrypt_hostname),
# so the host has to forward real inbound ports the same way it did for
# Pangolin's gerbil/traefik (see ../modules/guests/headscale.nix).
#
# /api/v1/* (headscale's REST API) is served on the same TLS listener as the
# Tailscale client protocol — headscale has no config knob to separate them
# onto different paths or ports — so it is technically reachable from the
# WAN too, but bearer-token gated (401 without a valid API key); no API key
# is ever provisioned ahead of time, mint one on demand over SSH when
# actually needed (`headscale apikeys create`). gRPC (`grpc_listen_addr`)
# stays at its own default of 127.0.0.1-only and is never forwarded below,
# so it is unreachable from the WAN regardless of what the API does.
#
# Stateful: headscale's own node/key database, its Noise and DERP private
# keys and its Let's Encrypt cert cache all live under /var/lib/headscale, a
# persistent volume — none of it regenerates across guest restarts.
#
# SSH is enabled for root, key-only, and reachable only from the host (not
# from other guests on the bridge or the WAN) — the `headscale` CLI (e.g.
# `apikeys create`, `preauthkeys create`) talks to the running server over a
# local unix socket, so it has to run on this guest itself. Two keys are
# authorized: adminSshKey for a human, and a host-generated one for
# headscale-mint-tailscale-authkey to run unattended (see
# ../modules/guests/headscale.nix).
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
  serverUrl,
  baseDomain,
  letsEncryptEmail,
  adminSshKey,
}:

{ lib, ... }:

let
  # headscale's tls_letsencrypt_hostname wants the bare hostname, not the
  # full URL.
  tlsHostname = lib.removePrefix "https://" serverUrl;
in
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
      allowedTCPPorts = [
        80 # ACME HTTP-01 challenge (tls_letsencrypt_listen)
        443 # headscale itself: client protocol + /api/v1, see note above
      ];
      # SSH (admin access, for one-off `headscale` CLI commands) is not in
      # allowedTCPPorts: it must only be reachable from the host, not from
      # other guests on the bridge or the WAN. extraCommands runs before the
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
    # Sets listen_addr to 0.0.0.0:443 and, because 443 < 1024, the module
    # grants CAP_NET_BIND_SERVICE automatically — which also covers the
    # ACME HTTP-01 listener's bind to :80, since it's the same process.
    address = "0.0.0.0";
    port = 443;
    settings = {
      server_url = serverUrl;
      acme_email = letsEncryptEmail;
      tls_letsencrypt_hostname = tlsHostname;
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
