# Pangolin entrypoint into the local infrastructure. newt is Pangolin's
# lightweight site connector: a fully userspace WireGuard client (netstack,
# no kernel module or capabilities needed) that dials out to the Pangolin
# server (../guests/pangolin.nix) and proxies its registered targets over the
# resulting tunnel. The VM only needs a config file with the site's id,
# secret and the server endpoint — created as a "Newt" site in the Pangolin
# dashboard, dashboard-managed the same way the old cloudflared tunnel was
# (see ../modules/guests/newt.nix).
#
# Stateless: the root filesystem is tmpfs and there is no SSH. newt's logs
# are mirrored to the serial console, so they show up on the host with
# `journalctl -u microvm@newt`.
#
# Called with its network coordinates by the host-side module; guests are
# evaluated by microvm.nix in a nested nixosSystem that gets none of the
# host's specialArgs, so they are passed in explicitly rather than read from
# the enclosing config.
{
  address,
  mac,
  gateway,
  prefixLength,
}:

{ pkgs, ... }:

let
  # Not in nixpkgs (only an unrelated TUI-widget library shares the name), so
  # built here the same way upstream's own flake.nix does: buildGoModule
  # against a pinned release tag. Bump version/hash/vendorHash together when
  # updating — `nix build` will report the correct hashes on a mismatch.
  newt = pkgs.buildGoModule rec {
    pname = "newt";
    version = "1.17.0";

    src = pkgs.fetchFromGitHub {
      owner = "fosrl";
      repo = "newt";
      rev = "v${version}";
      hash = "sha256-lwDywGs1Wh5jl9xwEd7KvXqEkLw7gCas44SbHtKx8Ps=";
    };

    vendorHash = "sha256-VOXZWcPnBSc8EKYLKhsrQTHSjXvpaEYoewYLCxJ8Nk8=";

    env.CGO_ENABLED = 0;
    ldflags = [
      "-s"
      "-w"
      "-X main.newtVersion=${version}"
    ];

    # Upstream's own test suite needs network access; skip it the same way
    # their flake does and rely on a version check instead.
    doCheck = false;

    meta = {
      description = "Userspace WireGuard tunnel client and TCP/UDP proxy for Pangolin";
      homepage = "https://github.com/fosrl/newt";
      mainProgram = "newt";
    };
  };
in
{
  microvm = {
    # credentialFiles is only implemented by the qemu runner.
    hypervisor = "qemu";
    vcpu = 1;
    mem = 512;
    interfaces = [
      {
        type = "tap";
        id = "vm-newt";
        inherit mac;
      }
    ];
  };

  # Credentials arrive over qemu's fw_cfg; its sysfs interface is a module, so
  # load it early enough for systemd to import them at boot.
  boot.initrd.kernelModules = [ "qemu_fw_cfg" ];

  networking = {
    useNetworkd = true;
    useDHCP = false;
    nameservers = [
      "1.1.1.1"
      "8.8.8.8"
    ];
  };
  systemd.network.networks."10-uplink" = {
    matchConfig.MACAddress = mac;
    address = [ "${address}/${toString prefixLength}" ];
    gateway = [ gateway ];
  };

  environment.systemPackages = [ newt ];

  # newt reads its config (endpoint, id, secret) from a single JSON file, the
  # same way cloudflared read a single token file — see
  # ../modules/guests/newt.nix for how that file is provisioned and its
  # shape.
  systemd.services.newt = {
    description = "Pangolin site connector (newt)";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${newt}/bin/newt --config-file %d/newt-config.json";
      ImportCredential = "newt-config";
      DynamicUser = true;
      Restart = "on-failure";
      RestartSec = "5s";
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
  };

  system.stateVersion = "26.05";
}
