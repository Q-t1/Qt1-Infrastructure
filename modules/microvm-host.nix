# Host side of the microVM layer: the guest bridge and the NAT that gets the
# guests off the box. Guests themselves live in ./guests/, one module each.
#
# The uplink interface is deliberately an option rather than a constant: which
# NIC the machine has is an OS fact owned by the host's own configuration, not
# something this repo should know.
{ config, lib, ... }:

let
  cfg = config.qt1.infra.microvmHost;
in
{
  options.qt1.infra.microvmHost = {
    enable = lib.mkEnableOption "the microVM host layer (bridge, NAT, declarative guests)";

    uplinkInterface = lib.mkOption {
      type = lib.types.str;
      example = "enp2s0";
      description = ''
        Interface the guests are masqueraded behind. Must be an interface that
        exists on the host; it is not managed by this module.
      '';
    };

    bridge = lib.mkOption {
      type = lib.types.str;
      default = "microvm";
      description = "Name of the bridge the guests' tap devices are enslaved to.";
    };

    hostAddress = lib.mkOption {
      type = lib.types.str;
      default = "10.100.0.1";
      description = "Host address on the guest network; the guests' default gateway.";
    };

    prefixLength = lib.mkOption {
      type = lib.types.int;
      default = 24;
      description = "Prefix length of the guest network.";
    };
  };

  config = lib.mkIf cfg.enable {
    microvm.host.enable = true;

    # Only the bridge and the guests' tap devices are handed to networkd; the
    # host's uplink stays with whatever manages it in the host configuration.
    systemd.network = {
      enable = true;
      # networkd manages no uplink here, so waiting on it would only stall boot.
      wait-online.enable = false;

      netdevs."10-${cfg.bridge}".netdevConfig = {
        Kind = "bridge";
        Name = cfg.bridge;
      };
      networks."10-${cfg.bridge}" = {
        matchConfig.Name = cfg.bridge;
        address = [ "${cfg.hostAddress}/${toString cfg.prefixLength}" ];
        # Keep the address while no guest is attached.
        networkConfig.ConfigureWithoutCarrier = true;
      };
      # Tap devices are created by microvm-tap-interfaces@<vm> as `vm-*`.
      networks."11-${cfg.bridge}-taps" = {
        matchConfig.Name = "vm-*";
        networkConfig.Bridge = cfg.bridge;
      };
    };

    networking.nat = {
      enable = true;
      internalInterfaces = [ cfg.bridge ];
      externalInterface = cfg.uplinkInterface;
    };
  };
}
