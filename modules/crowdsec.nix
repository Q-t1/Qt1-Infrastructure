{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.qt1.infra.crowdsec;
  host = config.qt1.infra.microvmHost;
  caddy = config.qt1.infra.guests.caddy;

  usingNftables = config.networking.nftables.enable;

  # Upstream keeps this private; regenerated so raw `cscli` finds /etc/crowdsec/config.yaml.
  crowdsecConfigFile =
    (pkgs.formats.yaml { }).generate "crowdsec.yaml"
      config.services.crowdsec.settings.general;

  # Upstream's only `L+` tmpfiles rules: link -> store path.
  localConfigLinks = lib.mapAttrs (_: rule: rule.link.argument) (
    lib.filterAttrs (_: rule: rule ? link) config.systemd.tmpfiles.settings."10-crowdsec"
  );

  # Upstream keeps these private too.
  localConfigDirs = map (dir: "/etc/crowdsec/${dir}") [
    "scenarios"
    "parsers/s00-raw"
    "parsers/s01-parse"
    "parsers/s02-enrich"
    "postoverflows/s01-whitelist"
    "contexts"
    "notifications"
  ];

  # Makes the /nix/store links in localConfigDirs match localConfigLinks exactly;
  # hub links and non-symlinks are left alone.
  syncLocalConfigLinks = pkgs.writeShellScript "crowdsec-sync-local-config" ''
    set -euo pipefail
    declare -A want=(
      ${lib.concatStringsSep "\n  " (
        lib.mapAttrsToList (
          link: target: "[${lib.escapeShellArg link}]=${lib.escapeShellArg target}"
        ) localConfigLinks
      )}
    )
    for dir in ${lib.escapeShellArgs localConfigDirs}; do
      for f in "$dir"/*; do
        [ -L "$f" ] || continue
        case "$(${lib.getExe' pkgs.coreutils "readlink"} -- "$f")" in
          /nix/store/*) ;;
          *) continue ;;
        esac
        if [ -z "''${want[$f]:-}" ]; then
          echo "removing stale local config $f"
          ${lib.getExe' pkgs.coreutils "rm"} -f -- "$f"
        fi
      done
    done
    for f in "''${!want[@]}"; do
      ${lib.getExe' pkgs.coreutils "mkdir"} -p -- "$(${lib.getExe' pkgs.coreutils "dirname"} -- "$f")"
      ${lib.getExe' pkgs.coreutils "ln"} -sfn -- "''${want[$f]}" "$f"
    done
  '';
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

    metricsFromGuests = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Serve CrowdSec's own Prometheus metrics to the guest bridge rather
        than on loopback only — parser/bucket/scenario counters, LAPI request
        counts per bouncer, and the number of currently active decisions
        (bans) by scenario. Off by default: with it off the endpoint stays on
        127.0.0.1, which is all `cscli metrics` needs.

        Turned on by qt1.infra.guests.monitoring when it collects them, since
        the Prometheus that scrapes them runs inside that guest while this
        service runs on the host. The endpoint is unauthenticated (CrowdSec
        has nothing to gate it with), which is why it is opened on the bridge
        interface only — never the uplink, and nothing forwards a WAN port to
        the host itself.
      '';
    };

    metricsPort = lib.mkOption {
      type = lib.types.port;
      default = 6060;
      readOnly = true;
      description = ''
        Port CrowdSec serves its Prometheus metrics on — its own default, and
        the scrape target qt1.infra.guests.monitoring reads when
        metricsFromGuests is set.
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

      # The GeoIP enrichers always run, but their mmdb files only ship with this
      # parser (normally pulled in by crowdsecurity/linux, which caddy doesn't need).
      hub.parsers = [ "crowdsecurity/geoip-enrich" ];

      localConfig.acquisitions = [
        {
          source = "journalctl";
          journalctl_filter = [ "_SYSTEMD_UNIT=microvm@caddy.service" ];
          labels.type = "caddy";
        }
      ];

      # crowdsecurity/caddy ships nothing for s00-raw, yet caddy-logs needs
      # evt.Parsed.program and .message (normally set by crowdsecurity/non-syslog).
      # Lines also arrive wrapped twice: the journal's `short` header, then the
      # serial-console prefix. Both are stripped, each optionally. Test with a line
      # that includes the journal header, since that's what the live agent sees.
      localConfig.parsers.s00Raw = [
        {
          name = "qt1/microvm-console";
          description = "Strip the journal header and serial-console prefix from the caddy guest's mirrored logs, and hand the line to the hub's caddy parser the way crowdsecurity/non-syslog would";
          filter = "evt.Line.Labels.type == 'caddy'";
          onsuccess = "next_stage";
          nodes = [
            {
              grok = {
                pattern = "^(?:%{SYSLOGTIMESTAMP} %{NOTSPACE} %{NOTSPACE}: )?(?:\\[\\s*%{NUMBER}\\] %{NOTSPACE}: )?%{GREEDYDATA:console_payload}$";
                apply_on = "Line.Raw";
              };
            }
          ];
          statics = [
            {
              parsed = "message";
              expression = "evt.Parsed.console_payload";
            }
            {
              parsed = "program";
              expression = "evt.Line.Labels.type";
            }
          ];
        }
      ];

      settings.general.api.server.enable = true;

      # Under state/: the crowdsec user can't write the root-owned rootDir itself.
      settings.lapi.credentialsFile = "/var/lib/crowdsec/state/local_api_credentials.yaml";

      # 0.0.0.0, not the bridge address: wait-online is off, and a failed bind
      # leaves the agent without metrics until restarted. The firewall scopes it.
      settings.general.prometheus.listen_addr = lib.mkIf cfg.metricsFromGuests "0.0.0.0";
    };

    networking.firewall.interfaces.${host.bridge}.allowedTCPPorts = lib.mkIf cfg.metricsFromGuests [
      cfg.metricsPort
    ];

    # ReadWritePaths fails the unit if rootDir doesn't exist yet; StateDirectory creates it.
    systemd.services.crowdsec.serviceConfig.StateDirectory = "crowdsec";

    # Upstream pairs DynamicUser with a static user, and its tmpfiles rules chown
    # state/ to that user, which breaks the idmapped /var/lib/private tree.
    # Migrating a host off /var/lib/private: see the README.
    systemd.services.crowdsec.serviceConfig.DynamicUser = lib.mkForce false;
    systemd.services.crowdsec-firewall-bouncer-register.serviceConfig.DynamicUser = lib.mkForce false;

    # localConfig arrives as tmpfiles symlinks, which don't restart the unit.
    systemd.services.crowdsec.restartTriggers = [
      (builtins.toJSON config.services.crowdsec.localConfig)
    ];

    # - The register unit runs raw `cscli`, which reads /etc/crowdsec/config.yaml.
    # - Upstream names localConfig links by store hash and never removes old ones,
    #   leaving duplicate parsers after every change.
    # Done here, not via tmpfiles, which a switch doesn't guarantee runs first.
    # mkBefore so a failure in upstream's own ExecStartPre can't skip it.
    systemd.services.crowdsec.serviceConfig.ExecStartPre = lib.mkBefore [
      "${lib.getExe' pkgs.coreutils "ln"} -sf ${crowdsecConfigFile} /etc/crowdsec/config.yaml"
      "${syncLocalConfigLinks}"
    ];

    services.crowdsec-firewall-bouncer = {
      enable = true;

      # FORWARD too: WAN traffic to caddy is forwarded, never delivered to INPUT.
      settings.iptables_chains = [
        "INPUT"
        "FORWARD"
      ];

      # Upstream's nftables ruleset hooks input only; ours (below) adds forward.
      createRulesets = !usingNftables;
    };

    # Upstream `requires` the register unit without ordering after it, racing its credential.
    systemd.services.crowdsec-firewall-bouncer.after = [
      "crowdsec-firewall-bouncer-register.service"
    ];

    # Upstream's script, except a failing `cscli bouncers list` fails the unit
    # instead of deleting the saved API key.
    systemd.services.crowdsec-firewall-bouncer-register.script =
      let
        bouncerName = config.services.crowdsec-firewall-bouncer.registerBouncer.bouncerName;
        apiKeyFile = "/var/lib/crowdsec-firewall-bouncer-register/api-key.cred";
      in
      lib.mkForce ''
        cscli=${lib.getExe' config.services.crowdsec.package "cscli"}
        bouncers=$($cscli bouncers list --output json)
        if ${lib.getExe pkgs.jq} -e -- ${lib.escapeShellArg "any(.[]; .name == \"${bouncerName}\")"} >/dev/null <<<"$bouncers"; then
          if [ ! -f ${apiKeyFile} ]; then
            echo "Bouncer registered but API key is not present"
            exit 1
          fi
        else
          rm -f '${apiKeyFile}'
          if ! $cscli bouncers add --output raw -- ${lib.escapeShellArg bouncerName} >${apiKeyFile}; then
            rm ${apiKeyFile}
            exit 1
          fi
        fi
      '';

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
