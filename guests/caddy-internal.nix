# caddy-internal: the tailnet-only counterpart of the WAN-facing caddy guest
# (./caddy.nix). One reverse proxy in front of every internal app, each
# served at its own MagicDNS name (<label>.<baseDomain>, e.g.
# grafana.ts.example.com) — the apps themselves never join the tailnet.
#
# Kept apart from ./caddy.nix on purpose: that one is port-forwarded from the
# WAN, this one never is, so no vhost mistake here can publish an internal
# app to the internet, and a compromise of the WAN-facing proxy doesn't hand
# over a tailnet node.
#
# How the names resolve: this guest joins the tailnet under a fixed node name
# (nodeName), and headscale serves every <label>.<baseDomain> as an extra
# DNS record pointing at this node's tailnet addresses — kept in sync by
# headscale-magicdns-aliases inside the headscale guest (see
# ./headscale.nix), since those addresses are assigned by headscale at
# registration, not known at build time.
#
# Reachability: caddy listens on port 80, opened only on tailscale0 — not the
# guest bridge, not (transitively) the WAN, since this guest never appears in
# the host's networking.nat.forwardPorts. Requests for anything but a
# declared vhost (this node's own MagicDNS name, its tailnet IP, …) get the
# connection closed. Upstreams are reached over the guest bridge; each app's
# own guest scopes its port to this guest's bridge address.
#
# Plain HTTP: headscale can't issue certificates for MagicDNS names the way
# Tailscale's own `tailscale cert` does, and the tailnet (WireGuard) already
# encrypts the traffic end to end.
#
# Called with its network coordinates, the tailnet it joins, the vhosts it
# serves, and the public caddy's bridge address/hostname (for the NAT-hairpin
# shortcut below) by the host-side module; guests are evaluated by
# microvm.nix in a nested nixosSystem that gets none of the host's
# specialArgs, so they are passed in explicitly rather than read from the
# enclosing config.
{
  address,
  mac,
  gateway,
  prefixLength,
  loginServerUrl,
  nodeName,
  baseDomain,
  virtualHosts,
  caddyAddress,
  tlsHostname,
}:

{ lib, ... }:

{
  imports = [ ../modules/tailscale-client.nix ];

  microvm = {
    # credentialFiles is only implemented by the qemu runner.
    hypervisor = "qemu";
    vcpu = 1;
    mem = 256;
    interfaces = [
      {
        type = "tap";
        # Interface names are capped at 15 characters.
        id = "vm-caddy-int";
        inherit mac;
      }
    ];
    volumes = [
      {
        # tailscaled's node key. Persisting it keeps this guest the same
        # tailnet node — same name, same addresses — across restarts, which
        # is what every alias record headscale serves for it points at.
        image = "tailscale-state.img";
        mountPoint = "/var/lib/tailscale";
        size = 64;
      }
    ];
  };

  boot.initrd.kernelModules = [ "qemu_fw_cfg" ];

  networking = {
    hostName = nodeName;
    useNetworkd = true;
    useDHCP = false;
    nameservers = [
      "1.1.1.1"
      "8.8.8.8"
    ];
    # See the README's "Joining the tailnet" section: this resolves
    # headscale's public hostname straight to the public caddy's bridge
    # address instead of round-tripping out through the WAN and back in via
    # the router's NAT (hairpinning, which not every router supports), for
    # this guest's own tailscale-autoconnect run below.
    hosts.${caddyAddress} = [ tlsHostname ];
    firewall.interfaces.tailscale0.allowedTCPPorts = [ 80 ];
  };
  systemd.network.networks."10-uplink" = {
    matchConfig.MACAddress = mac;
    address = [ "${address}/${toString prefixLength}" ];
    gateway = [ gateway ];
  };

  qt1.infra.tailscaleClient = {
    enable = true;
    inherit loginServerUrl;
    authKeyFile = "/run/credentials/tailscale-autoconnect.service/tailscale-authkey";
    # Not ephemeral: /var/lib/tailscale is a persistent volume above, so
    # restarts reuse the same node — an ephemeral one would be deleted by
    # headscale whenever the VM stays down past its inactivity timeout,
    # taking its addresses (and so every alias record) with it.
    ephemeral = false;
    # Pinned explicitly rather than inherited from the OS hostname: this is
    # the node name headscale-magicdns-aliases looks up.
    extraUpFlags = [ "--hostname=${nodeName}" ];
  };
  # tailscale-client.nix declares the credential path above but not the
  # import itself — importing the fw_cfg credential this guest's own host
  # module hands in via microvm.credentialFiles.tailscale-authkey.
  systemd.services.tailscale-autoconnect.serviceConfig.ImportCredential = [ "tailscale-authkey" ];

  services.caddy = {
    enable = true;
    # Every site below is plain http://; nothing here should ever try ACME.
    globalConfig = ''
      auto_https off
    '';
    virtualHosts = lib.mapAttrs' (
      label: upstream:
      lib.nameValuePair "http://${label}.${baseDomain}" {
        # Access log to the journal instead of the module's default
        # per-vhost file (named after the whole site address, scheme
        # included).
        logFormat = "output stdout";
        extraConfig = ''
          reverse_proxy ${upstream}
        '';
      }
    ) virtualHosts;
    # Catch-all for any Host not declared above — the node's own MagicDNS
    # name, its tailnet IP, anything else: close the connection without a
    # response. Caddy always prefers the more specific site addresses above.
    extraConfig = ''
      http:// {
        abort
      }
    '';
  };

  system.stateVersion = "26.05";
}
