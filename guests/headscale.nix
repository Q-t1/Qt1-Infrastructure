# headscale (Tailscale coordination server) and headplane (its web UI),
# collocated on one guest. Both are reached from outside only through the
# cloudflared guest's dashboard-managed tunnel, routed to this guest's
# address on the guest bridge (see ../modules/guests/headscale.nix and the
# README) — nothing here opens a port on the host or the WAN.
#
# Stateful, unlike the cloudflared guest: headscale's node/key database and
# headplane's own data live on persistent volumes rather than the default
# tmpfs root, so they survive guest restarts.
#
# SSH is enabled for root, key-only, and reachable only from the host (not
# from other guests on the bridge) — the `headscale` CLI (e.g. `apikeys
# create`) talks to the running server over a local socket, so it has to run
# on this guest itself. Two keys are authorized: adminSshKey for a human, and
# a host-generated one for headscale-mint-tailscale-authkey to run
# unattended (see ../modules/guests/headscale.nix).
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
  headplaneUrl,
  adminSshKey,
}:

{ lib, ... }:

{
  microvm = {
    # credentialFiles (for headplane's cookie secret) is only implemented by
    # the qemu runner.
    hypervisor = "qemu";
    vcpu = 2;
    mem = 1024;
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
      {
        image = "headplane-data.img";
        mountPoint = "/var/lib/headplane";
        size = 256;
      }
    ];
  };

  # Credentials (headplane's cookie secret) arrive over qemu's fw_cfg; its
  # sysfs interface is a module, so load it early enough for systemd to
  # import them at boot.
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
        8080
        3000
      ];
      # SSH (admin access, for one-off `headscale` CLI commands) is not in
      # allowedTCPPorts: it must only be reachable from the host, not from
      # other guests on the bridge. extraCommands runs before the firewall's
      # default-drop rule, so this is the only way in on port 22.
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
    # way as headplane's cookie secret.
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
    address = "0.0.0.0";
    port = 8080;
    settings = {
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

  services.headplane = {
    enable = true;
    settings = {
      server = {
        host = "0.0.0.0";
        port = 3000;
        base_url = headplaneUrl;
        # Cloudflare Tunnel terminates TLS at the edge; the backend hop from
        # cloudflared to this guest is plain HTTP, but the browser only ever
        # sees https://, so the Secure cookie attribute is still correct.
        cookie_secret_path = "/run/credentials/headplane.service/headplane-cookie-secret";
      };
      # config_path and headscale.url default to headscale's own configFile
      # and localhost port, which is correct here since both run on this
      # guest.
    };
  };

  # Headplane needs its cookie secret in its own credential store; the
  # credential itself is imported at the VM level from the host (see
  # ../modules/guests/headscale.nix).
  systemd.services.headplane.serviceConfig.ImportCredential = "headplane-cookie-secret";

  system.stateVersion = "26.05";
}
