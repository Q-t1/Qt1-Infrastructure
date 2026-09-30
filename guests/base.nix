{ config, lib, ... }:

let
  cfg = config.qt1.guest;
  inherit (import ../lib.nix { inherit lib; }) publicResolvers;
in
{
  imports = [ ../modules/tailscale-client.nix ];

  options.qt1.guest = {
    name = lib.mkOption {
      type = lib.types.str;
      description = "VM name; also the guest's hostname.";
    };
    address = lib.mkOption {
      type = lib.types.str;
      description = "The guest's address on the guest bridge.";
    };
    mac = lib.mkOption {
      type = lib.types.str;
      description = "MAC of the guest's tap interface.";
    };
    gateway = lib.mkOption {
      type = lib.types.str;
      description = "The host's address on the guest bridge.";
    };
    prefixLength = lib.mkOption {
      type = lib.types.int;
      description = "Prefix length of the guest network.";
    };
    tapId = lib.mkOption {
      type = lib.types.str;
      default = "vm-${cfg.name}";
      description = ''
        Name of the guest's tap interface on the host. Must start with `vm-`
        (the host bridges `vm-*`) and fit in 15 characters.
      '';
    };

    allowedTCPPortsFrom = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            port = lib.mkOption { type = lib.types.port; };
            from = lib.mkOption {
              type = lib.types.str;
              description = "Source address allowed to reach `port`.";
            };
          };
        }
      );
      default = [ ];
      description = ''
        TCP ports opened on the bridge to a single source address only (the
        host, or one other guest) rather than to everything on it. Added
        with extraCommands, which runs before the firewall's default-drop
        rule.
      '';
    };

    tailnet = {
      enable = lib.mkEnableOption ''
        joining the tailnet as a stable node named after the guest.
        tailscaled's state lives on a persistent volume and the node is not
        ephemeral, so restarts keep the same node, name and addresses
      '';
      loginServerUrl = lib.mkOption {
        type = lib.types.str;
        description = "headscale's public serverUrl.";
      };
      loginServerAddress = lib.mkOption {
        type = lib.types.str;
        description = "Bridge address loginServerUrl's hostname is resolved to (the caddy guest).";
      };
    };
  };

  config = lib.mkMerge [
    {
      microvm = {
        # credentialFiles is only implemented by the qemu runner.
        hypervisor = "qemu";
        interfaces = [
          {
            type = "tap";
            id = cfg.tapId;
            inherit (cfg) mac;
          }
        ];
      };

      # Credentials arrive over fw_cfg; load it early enough for systemd to import them.
      boot.initrd.kernelModules = [ "qemu_fw_cfg" ];

      networking = {
        hostName = cfg.name;
        useNetworkd = true;
        useDHCP = false;
        nameservers = publicResolvers;
        firewall.extraCommands = lib.mkIf (cfg.allowedTCPPortsFrom != [ ]) (
          lib.concatMapStrings (rule: ''
            iptables -A nixos-fw -p tcp --dport ${toString rule.port} -s ${rule.from} -j nixos-fw-accept
          '') cfg.allowedTCPPortsFrom
        );
      };
      systemd.network.networks."10-uplink" = {
        matchConfig.MACAddress = cfg.mac;
        address = [ "${cfg.address}/${toString cfg.prefixLength}" ];
        gateway = [ cfg.gateway ];
      };

      system.stateVersion = lib.mkDefault "26.05";
    }

    (lib.mkIf cfg.tailnet.enable {
      microvm.volumes = [
        {
          image = "tailscale-state.img";
          mountPoint = "/var/lib/tailscale";
          size = 64;
        }
      ];

      qt1.infra.tailscaleClient = {
        enable = true;
        inherit (cfg.tailnet) loginServerUrl loginServerAddress;
        authKeyFile = "/run/credentials/tailscale-autoconnect.service/tailscale-authkey";
        hostname = cfg.name;
        # headscale deletes inactive ephemeral nodes, taking their name and addresses.
        ephemeral = false;
      };
      systemd.services.tailscale-autoconnect.serviceConfig.ImportCredential = [ "tailscale-authkey" ];
    })
  ];
}
