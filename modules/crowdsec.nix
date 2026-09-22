# Host-side CrowdSec: watches the caddy guest's mirrored console log for
# the scenarios in the crowdsecurity/caddy hub collection (bruteforce,
# scanners, common HTTP attacks) and bans offending IPs with the local
# firewall bouncer.
#
# Lives on the host, not as its own microVM. Two things make the host the
# only sane place for this: caddy has no SSH and no log file of its own —
# its logs only ever land in the host's journal, mirrored via its console
# (see guests/caddy.nix and the README's "caddy guest" section) — and
# banning an IP means touching the host's own WAN-facing NAT/forwardPorts
# (modules/microvm-host.nix), which only the host owns. A separate guest
# would need both shipped to it and bans shipped back, for no isolation
# benefit.
{
  config,
  lib,
  ...
}:

let
  cfg = config.qt1.infra.crowdsec;
  caddy = config.qt1.infra.guests.caddy;

  # Mirrors the same condition services.crowdsec-firewall-bouncer.settings.mode
  # picks its default from, so our own ruleset (below) stays in step with
  # whichever backend the host actually uses.
  usingNftables = config.networking.nftables.enable;
in
{
  options.qt1.infra.crowdsec = {
    enable = lib.mkEnableOption "CrowdSec, watching the caddy guest's logs and banning offenders at the host firewall";

    collections = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "crowdsecurity/caddy" ];
      description = ''
        Hub collections to install (parsers + scenarios). The default just
        covers the one acquisition this module wires up below (the caddy
        guest's mirrored console log) — add more only alongside a matching
        acquisition of your own (services.crowdsec.localConfig.acquisitions),
        or they're dead config that never sees any events.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = caddy.enable;
        message = "qt1.infra.crowdsec requires qt1.infra.guests.caddy.enable — its only configured log source is that guest's mirrored console output (microvm@caddy.service).";
      }
    ];

    services.crowdsec = {
      enable = true;
      hub.collections = cfg.collections;

      localConfig.acquisitions = [
        {
          source = "journalctl";
          # Caddy's own stdout/stderr are mirrored to its console (see
          # guests/caddy.nix's StandardOutput/StandardError), which is what
          # lands here: the host's journal, under the unit QEMU's serial
          # console feeds — the same stream the README already points a
          # human at with `journalctl -u microvm@caddy`.
          journalctl_filter = [ "_SYSTEMD_UNIT=microvm@caddy.service" ];
          labels.type = "caddy";
        }
      ];

      # Needed for the firewall bouncer below to authenticate against a
      # local API at all; stays loopback-only (127.0.0.1:8080 by default),
      # never reachable from the guest bridge or the WAN.
      settings.general.api.server.enable = true;

      # With a local API running, crowdsec is also that API's own first
      # client (it self-registers as a "machine" via `cscli machine add
      # --auto` the first time this file doesn't exist) — mandatory once
      # api.server.enable is true, upstream has no default for it.
      #
      # Must live under state/, not directly in /var/lib/crowdsec: the
      # crowdsec user only owns the subdirectories upstream's own tmpfiles
      # rules create (state/, hub/, ...) — the bare rootDir stays
      # root:root 0755, so a file placed straight in it fails to write
      # with EACCES the first time crowdsec tries to create it.
      settings.lapi.credentialsFile = "/var/lib/crowdsec/state/local_api_credentials.yaml";
    };

    services.crowdsec-firewall-bouncer = {
      enable = true;

      # In iptables mode the bouncer inserts its own DROP-if-blacklisted
      # rule at the head of every chain listed here — ahead of whatever
      # else already lives there, which is what makes the ordering below
      # safe regardless of service start order.
      #
      # Crucially this must include FORWARD, not just the INPUT default:
      # the WAN traffic this exists to block is never delivered to the
      # host itself, it's FORWARDed on to the caddy guest by
      # modules/microvm-host.nix's NAT (networking.nat.forwardPorts) — a
      # rule only on INPUT would silently never fire.
      settings.iptables_chains = [
        "INPUT"
        "FORWARD"
      ];

      # nftables mode has no equivalent knob — the ruleset createRulesets
      # would generate hooks `input` only (hardcoded upstream) — so hand
      # it a ruleset of our own that hooks `forward` too, using the same
      # table/set names the bouncer defaults to feeding.
      createRulesets = !usingNftables;
    };

    networking.nftables.tables = lib.mkIf usingNftables {
      crowdsec = {
        family = "ip";
        content = ''
          set crowdsec-blacklists {
            type ipv4_addr
            flags timeout
          }
          chain crowdsec-chain-input {
            type filter hook input priority filter - 5; policy accept;
            ip saddr @crowdsec-blacklists drop
          }
          chain crowdsec-chain-forward {
            type filter hook forward priority filter - 5; policy accept;
            ip saddr @crowdsec-blacklists drop
          }
        '';
      };
      crowdsec6 = {
        family = "ip6";
        content = ''
          set crowdsec6-blacklists {
            type ipv6_addr
            flags timeout
          }
          chain crowdsec6-chain-input {
            type filter hook input priority filter - 5; policy accept;
            ip6 saddr @crowdsec6-blacklists drop
          }
          chain crowdsec6-chain-forward {
            type filter hook forward priority filter - 5; policy accept;
            ip6 saddr @crowdsec6-blacklists drop
          }
        '';
      };
    };
  };
}
