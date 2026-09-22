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
  pkgs,
  ...
}:

let
  cfg = config.qt1.infra.crowdsec;
  caddy = config.qt1.infra.guests.caddy;

  # Mirrors the same condition services.crowdsec-firewall-bouncer.settings.mode
  # picks its default from, so our own ruleset (below) stays in step with
  # whichever backend the host actually uses.
  usingNftables = config.networking.nftables.enable;

  # The same pkgs.formats.yaml{}.generate call upstream's own crowdsec.nix
  # makes internally for services.crowdsec.settings.general — regenerated
  # here (rather than read back from upstream, which keeps it as a
  # private `let` binding, not a reachable option) purely to give raw
  # `cscli` invocations a valid config at their conventional default path;
  # see the comment below on crowdsec-firewall-bouncer-register.service.
  crowdsecConfigFile = (pkgs.formats.yaml { }).generate "crowdsec.yaml" config.services.crowdsec.settings.general;
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

    # Upstream declares crowdsec.service with plain ReadWritePaths for
    # rootDir (/var/lib/crowdsec), relying on systemd.tmpfiles.settings to
    # have already created it — but ReadWritePaths doesn't create missing
    # paths itself, it hard-fails the unit if the target isn't already
    # there ("Failed to set up mount namespacing: /var/lib/crowdsec: No
    # such file or directory"), and whether tmpfiles has actually run for
    # a brand new rule by the time this unit first starts isn't
    # guaranteed on a `nixos-rebuild switch` that introduces both at once.
    # StateDirectory= sidesteps that race entirely: it's created directly
    # by PID1 as part of starting *this* unit, synchronously, every time —
    # the same mechanism that (as it happens) reliably created this exact
    # path for crowdsec-firewall-bouncer-register.service below, before it
    # got scoped down to its own directory.
    systemd.services.crowdsec.serviceConfig.StateDirectory = "crowdsec";

    # Upstream's crowdsec-firewall-bouncer-register.service (part of
    # services.crowdsec-firewall-bouncer below, not this module) declares
    # `StateDirectory = "crowdsec-firewall-bouncer-register crowdsec"`. That
    # second name is what actually breaks crowdsec.service itself:
    # DynamicUser's StateDirectory machinery turns /var/lib/crowdsec into a
    # symlink into the root-only /var/lib/private/, and only sets up the
    # bind mount that makes it writable *inside this register unit's own
    # sandbox* — not crowdsec.service's, which only has plain
    # ReadWritePaths and has no way through that symlink anymore
    # (`mkdir: cannot create directory '/var/lib/crowdsec': Permission
    # denied` the first time crowdsec.service starts after this one has).
    # The register script never actually touches /var/lib/crowdsec — it
    # only writes its own api-key.cred and talks to the LAPI over HTTP —
    # so the fix is dropping the claim here, not chasing it in the main
    # service.
    systemd.services.crowdsec-firewall-bouncer-register.serviceConfig.StateDirectory =
      lib.mkForce "crowdsec-firewall-bouncer-register";

    # That same register unit's script also invokes the raw `cscli`
    # binary directly — unlike every other cscli invocation here, which
    # goes through services.crowdsec's own generated wrapper
    # (environment.systemPackages) that always passes `-c=<the real
    # config>`. Without it, cscli falls back to its conventional default,
    # /etc/crowdsec/config.yaml, which NixOS's crowdsec module never
    # actually writes there (the real config lives in the Nix store):
    #   Error: while reading yaml file: open /etc/crowdsec/config.yaml: no such file or directory
    #
    # Fixed by symlinking that conventional path into place — but as an
    # extra ExecStartPre on crowdsec.service itself (which already has
    # /etc/crowdsec writable, and which the register unit is ordered
    # after), not a separate systemd.tmpfiles rule: we just learned the
    # hard way, fixing crowdsec.service's own StateDirectory above, that a
    # brand new tmpfiles rule isn't guaranteed applied by the very switch
    # that introduces it. This way there's nothing else to race.
    systemd.services.crowdsec.serviceConfig.ExecStartPre = [
      "${lib.getExe' pkgs.coreutils "ln"} -sf ${crowdsecConfigFile} /etc/crowdsec/config.yaml"
    ];

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
