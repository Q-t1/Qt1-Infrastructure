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
  host = config.qt1.infra.microvmHost;
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
  crowdsecConfigFile =
    (pkgs.formats.yaml { }).generate "crowdsec.yaml"
      config.services.crowdsec.settings.general;
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

      # crowdsec registers its GeoIpCity/GeoIpASN enrichers at startup no
      # matter what, but the databases they read (GeoLite2-City.mmdb,
      # GeoLite2-ASN.mmdb, in the data dir) are only ever downloaded as the
      # data files of this hub parser. It normally comes in through
      # crowdsecurity/linux, which the caddy collection does not depend on,
      # so without it here the agent logged "unable to open
      # GeoLite2-City.mmdb" on every start and alerts carried no country,
      # AS or source range. Source-agnostic: it enriches any event with a
      # public source_ip (it skips private and loopback ranges itself), so
      # it needs no acquisition of its own, unlike cfg.collections.
      hub.parsers = [ "crowdsecurity/geoip-enrich" ];

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

      # The one parser that makes any of the above produce an event, and it
      # has two jobs — both of which have to happen before
      # crowdsecurity/caddy-logs (s01-parse) can do anything:
      #
      #  1. Strip everything in front of caddy's JSON. caddy-logs unmarshals
      #     the line as JSON, and a prefixed line is not JSON. There are two
      #     layers of prefix. The acquisition reads the caddy guest's mirrored
      #     console, which wraps each line as
      #     `[   12.345678] caddy[480]: {"level":...}`. Then the journalctl
      #     source runs `journalctl --follow` with no `-o`, so the host's
      #     journal adds its default `short` header in front of that:
      #     `Sep 29 22:30:44 homelab-1 microvm@caddy[702795]: [   12.345678] ...`.
      #     Both are optional in the pattern, so a line that ever arrives with
      #     either one missing (or bare) parses too.
      #
      #     The first version only stripped the console prefix, anchored at
      #     the start of the line. The journal header sat in front of it, so
      #     the whole line went through as the message and every live line
      #     failed caddy-logs. It passed `cscli explain` because the test line
      #     had been copied without that header.
      #
      #  2. Set evt.Parsed.message and evt.Parsed.program, which is what
      #     caddy-logs actually filters on (`evt.Parsed.program startsWith
      #     'caddy'`). Normally crowdsecurity/non-syslog does this, but that
      #     parser ships inside crowdsecurity/syslog-logs, which the
      #     crowdsecurity/caddy collection does not depend on: the collection
      #     installs caddy-logs (s01) and http-logs (s02) and nothing in
      #     s00-raw at all. Without this, every line failed the very first
      #     stage even when it was clean JSON.
      #
      # Ordering is safe: crowdsec sorts parsers by their path, this is the
      # only thing in s00-raw, and the name the nixpkgs module gives it
      # (parsers-s00-raw.yaml) sorts ahead of anything a hub collection would
      # install beside it.
      #
      # Verified with `cscli explain` against a real line off this host: the
      # chain now reaches s01-parse, s02-enrich and the scenarios
      # (http-probing, http-sensitive-files, http-crawl-non_statics on a 404
      # probe), and a systemd line from the same console still fails
      # caddy-logs — i.e. it stays counted as unparsed instead of becoming a
      # bogus event.
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

      # Where CrowdSec serves its own Prometheus metrics. Upstream already
      # enables that endpoint, at the "full" level which carries
      # cs_active_decisions and the per-bouncer LAPI counters, but binds it to
      # 127.0.0.1 — unreachable for the Prometheus that scrapes it, which runs
      # inside the monitoring guest on the other side of the bridge. See
      # metricsFromGuests, which qt1.infra.guests.monitoring sets.
      #
      # All interfaces rather than the bridge address, with the firewall rule
      # below as the thing that actually scopes it — the same trade Grafana
      # makes inside its own guest. Binding the bridge address would be a
      # boot-order gamble this service cannot recover from: the host's
      # networkd has wait-online disabled (it manages no uplink, see
      # microvm-host.nix), so network-online.target doesn't wait for the
      # bridge to get its address, and CrowdSec's metrics listener only logs
      # "serving metrics" once and gives up if the bind fails — leaving the
      # agent running with no metrics until someone restarts it.
      settings.general.prometheus.listen_addr = lib.mkIf cfg.metricsFromGuests "0.0.0.0";
    };

    # The one thing keeping that listener off the WAN: the port is opened on
    # the bridge interface only, and the endpoint is unauthenticated (CrowdSec
    # has nothing to gate it with). The host's firewall default-drops
    # everywhere else, and nothing forwards a WAN port to the host itself.
    networking.firewall.interfaces.${host.bridge}.allowedTCPPorts = lib.mkIf cfg.metricsFromGuests [
      cfg.metricsPort
    ];

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

    # Both units that claim that StateDirectory run as upstream's *static*
    # crowdsec user (uid from users.users.crowdsec), yet upstream also sets
    # DynamicUser = true on them. That combination gives two owners for one
    # tree, and they disagree:
    #
    #  - DynamicUser moves the directory to /var/lib/private/crowdsec,
    #    owned by `nobody` on disk, and mounts it *idmapped* into each unit
    #    so that nobody reads as the service user inside. Everything
    #    crowdsec or cscli creates there (crowdsec.db, state/trace, ...)
    #    lands on disk as nobody.
    #  - Upstream's tmpfiles rules for state/ and state/hub/ name the real
    #    crowdsec user, and the `d` type re-chowns an existing directory.
    #    On disk, crowdsec's uid is *not* what the idmapped mount maps, so
    #    inside the units state/ then reads as someone else's 0750
    #    directory: no way in.
    #
    # Nothing noticed for a week because tmpfiles only re-runs on a switch
    # that changes some tmpfiles rule (or on boot). The first one after the
    # move to private/ (the s00-raw parser's symlink) chowned state/ back to
    # crowdsec and broke the register unit
    # (`mkdir /var/lib/crowdsec/state/trace: permission denied`). The
    # still-running crowdsec would have failed the same way on its next
    # restart. The next tmpfiles run then hit the nobody-owned parent and
    # refused ("Detected unsafe path transition").
    #
    # So these units drop DynamicUser. The user is static anyway, and every
    # other sandboxing setting upstream applies stays. The state lives at a
    # plain /var/lib/crowdsec, owned by crowdsec throughout, which is what
    # the tmpfiles rules already assume. Migrating an existing host from
    # /var/lib/private is a one-off manual step; see the README.
    systemd.services.crowdsec.serviceConfig.DynamicUser = lib.mkForce false;
    systemd.services.crowdsec-firewall-bouncer-register.serviceConfig.DynamicUser = lib.mkForce false;

    # Local parsers (and scenarios, etc.) reach crowdsec as tmpfiles
    # symlinks under /etc/crowdsec, not through its unit or its config file.
    # A switch that only changes one of them leaves the unit untouched, so
    # the running agent never loads the change: c903e20's parser was
    # deployed and then sat idle for exactly that reason.
    systemd.services.crowdsec.restartTriggers = [
      (builtins.toJSON config.services.crowdsec.localConfig)
    ];

    # NOTE for readers of the git history: an earlier version of this file
    # stripped "crowdsec" out of crowdsec-firewall-bouncer-register.service's
    # own StateDirectory (upstream declares
    # `StateDirectory = "crowdsec-firewall-bouncer-register crowdsec"`),
    # reasoning that DynamicUser's StateDirectory machinery turning
    # /var/lib/crowdsec into a symlink into the root-only /var/lib/private/
    # was what broke crowdsec.service's own (then plain-ReadWritePaths-only)
    # access to it. That diagnosis was half right: it fixed
    # crowdsec.service, but on the wrong unit, and broke something this
    # one separately needs it for. crowdsec.service now has its own
    # StateDirectory = "crowdsec" (above), which is the actual, unit-scoped
    # fix, and doesn't care what any other unit with the same claim does —
    # so upstream's original declaration on this unit is safe to leave
    # alone, and turns out to be required: `cscli`'s own trace-directory
    # setup (unrelated to the bouncer-registration logic itself) also
    # needs to resolve /var/lib/crowdsec, and without a StateDirectory of
    # its own this unit has no way through that same symlink either
    # (`Error: while setting up trace directory: mkdir /var/lib/crowdsec:
    # file exists` — Go's os.MkdirAll can't tell "permission denied
    # resolving the symlink" from "doesn't exist", tries plain Mkdir, gets
    # EEXIST from the symlink's own dirent, and re-surfaces that error
    # once its own fallback Lstat check sees a symlink instead of a
    # directory).

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
    #
    # mkBefore, not a plain list append: upstream's own ExecStartPre
    # commands (hub install, machine registration) run first otherwise,
    # and systemd stops at the first ExecStartPre that fails — so an
    # unrelated failure in *those* (e.g. a stale machine record from an
    # earlier broken run) would silently keep this symlink from ever
    # being created too, reproducing the exact error this exists to fix
    # for no reason connected to it.
    systemd.services.crowdsec.serviceConfig.ExecStartPre = lib.mkBefore [
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

    # Upstream's crowdsec-firewall-bouncer.service `requires` the register
    # unit above (it needs the API key that unit writes, loaded via
    # LoadCredential) but never adds a matching `after` — `requires`
    # alone is a failure-propagation dependency, not an ordering one, so
    # systemd is free to start both in parallel. On a cold start that
    # race can lose:
    #   crowdsec-firewall-bouncer.service: Failed to set up credentials: No such file or directory
    # (Failed at step CREDENTIALS, exit 243) — the bouncer trying to load
    # a credential file the register unit hasn't written yet.
    systemd.services.crowdsec-firewall-bouncer.after = [
      "crowdsec-firewall-bouncer-register.service"
    ];

    # Upstream's register script, with one change: a failing `cscli bouncers
    # list` now fails the unit. Upstream pipes it straight into `jq -e` and
    # reads any failure as "not registered", then deletes the saved API key
    # before trying `cscli bouncers add`. When cscli itself is what's broken,
    # the add fails too, and the host is left with the bouncer registered in
    # the LAPI but no key on disk. That fails every later run ("Bouncer
    # registered but API key is not present"), and the bouncer can't start
    # again until someone runs `cscli bouncers delete` by hand. It happened
    # here with the permissions breakage described above: an unrelated
    # cscli error turned into a bouncer outage at the next restart.
    #
    # Querying first, under the unit's `set -e`, means a cscli error stops
    # the run before anything is deleted. The existing key stays, and the
    # next run after the actual fix just finds it.
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
