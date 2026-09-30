# Host side of the gatus guest: the VM entry, its public vhost on the
# WAN-facing caddy, the endpoints it checks — derived from the other guests'
# own options, so a service added elsewhere in this repo shows up on the
# status page without being listed twice — and the host-side timer that
# pushes each microVM's systemd state to it. See ../../guests/gatus.nix for
# the guest's own configuration.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  infraLib = import ../../lib.nix { inherit lib; };
  headscale = config.qt1.infra.guests.headscale;
  caddy = config.qt1.infra.guests.caddy;
  caddyInternal = config.qt1.infra.guests.caddyInternal;
  cfg = config.qt1.infra.guests.gatus;

  # Must match guests/gatus.nix.
  webPort = 8080;

  # The status page is public, so nothing on it names an internal address,
  # port or hostname — only each endpoint's name, its conditions and whether
  # they held. Errors go too: a failed check's error reads
  # `dial tcp 10.100.0.5:443: ...`. Read them in `journalctl -u
  # microvm@gatus` on the host instead.
  hideInternals = {
    hide-hostname = true;
    hide-url = true;
    hide-port = true;
    hide-errors = true;
  };

  # headscale through the WAN-facing caddy: the same TLS certificate and
  # proxy every Tailscale client goes through. /health answers 200 when
  # headscale can reach its own database, 500 otherwise. The hostname
  # resolves to caddy's bridge address inside the guest (see
  # guests/gatus.nix), not out through the WAN and back in.
  headscaleEndpoint = {
    name = "Headscale";
    group = "Public";
    url = "https://${headscale.tlsHostname}/health";
    interval = "1m";
    conditions = [
      "[STATUS] == 200"
      "[BODY].status == pass"
      # Caddy renews once a third of the lifetime is left (a month, for
      # today's 90-day certificates), so a week left means renewal has been
      # failing for weeks.
      "[CERTIFICATE_EXPIRATION] > 168h"
    ];
    ui = hideInternals;
  };

  # Every app on caddy-internal, at the URL a tailnet client uses, but reached
  # over the bridge: the names resolve to caddy-internal's bridge address
  # inside the guest, and caddy-internal opens 443 to this guest for it
  # (probesFromGatus). That checks proxy and app together, the way a
  # browser sees them.
  #
  # Certificate verification is off for these: they are issued by
  # caddy-internal's own local CA, generated at runtime, which this guest has
  # no copy of. The hop is one bridge hop, and what's checked is
  # reachability, not identity.
  tailnetEndpoints = lib.mapAttrsToList (label: url: {
    name = label;
    group = "Tailnet";
    inherit url;
    interval = "1m";
    client.insecure = true;
    # Redirects are followed (Grafana's `/` sends you to /login), so this is
    # the status of the page a browser would land on. A 502 here is caddy
    # saying the app behind it is down.
    conditions = [ "[STATUS] < 400" ];
    ui = hideInternals;
  }) (lib.optionalAttrs caddyInternal.enable caddyInternal.urls);

  # Each microVM's `microvm@<name>` unit, as the host's systemd sees it. The
  # guest can't see that from inside, so these are gatus *external*
  # endpoints: the host pushes their results (gatus-push-microvms, below)
  # and gatus only stores and shows them. The heartbeat marks one down when
  # nothing arrives for five pushes in a row, so a stalled pusher shows up
  # red rather than as a stale green.
  microvmGroup = "MicroVMs";
  microvmEndpoints = map (vm: {
    name = vm;
    group = microvmGroup;
    # Expanded by gatus from its environment; see guests/gatus.nix.
    token = "\${GATUS_PUSH_TOKEN}";
    heartbeat.interval = "5m";
  }) cfg.microvms;

  # The key gatus files an endpoint under, `<group>_<name>`, which is what
  # its push API is addressed by. Must match gatus's own key.sanitize
  # (config/key/key.go).
  gatusKey =
    let
      sanitize =
        s:
        lib.replaceStrings [
          "/"
          "_"
          "."
          ","
          " "
          "#"
          "+"
          "&"
        ] (lib.genList (_: "-") 8) (lib.toLower (lib.trim s));
    in
    group: name: "${sanitize group}_${sanitize name}";
in
{
  options.qt1.infra.guests.gatus =
    infraLib.guestOptions {
      index = 6;
      description = "the gatus microVM (public status page, served by the WAN-facing caddy)";
    }
    // {
      hostname = lib.mkOption {
        type = lib.types.str;
        example = "status.example.com";
        description = ''
          Public hostname the status page is served at, by the WAN-facing
          caddy guest (qt1.infra.guests.caddy), with a Let's Encrypt
          certificate of its own. Needs a DNS record pointing at this host's
          WAN address, the same as headscale's serverUrl.
        '';
      };

      url = lib.mkOption {
        type = lib.types.str;
        default = "https://${cfg.hostname}/";
        readOnly = true;
        description = "Where the status page answers, publicly.";
      };

      endpoints = lib.mkOption {
        type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
        default = [ ];
        example = [
          {
            name = "Blog";
            group = "Public";
            url = "https://blog.example.com/";
            conditions = [ "[STATUS] == 200" ];
          }
        ];
        description = ''
          Extra endpoints to check, in gatus's own format
          (https://gatus.io/docs), on top of the ones this module derives:
          headscale through the public caddy, and every
          qt1.infra.guests.caddyInternal.virtualHosts entry through
          caddy-internal. Everything here is shown on a public page, so set
          `ui.hide-url` and friends on anything internal.
        '';
      };

      microvms = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = lib.remove "gatus" config.microvm.autostart;
        defaultText = lib.literalExpression ''lib.remove "gatus" config.microvm.autostart'';
        example = [
          "caddy"
          "headscale"
        ];
        description = ''
          microVMs whose `microvm@<name>` unit is shown on the status page,
          under "MicroVMs": up while the host's systemd reports the unit
          `active`, down otherwise. Defaults to every VM the host starts at
          boot, declared by this repo or not, except gatus itself — its page
          is down whenever it is. Each name is shown publicly.
        '';
      };

      pushTokenFile = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/microvms/gatus/push-token";
        description = ''
          Host path holding the bearer token the host pushes microVM states
          to gatus with (see `microvms`), generated the first time this path
          doesn't exist (gatus-provision-secrets, see ../../lib.nix) and
          passed into the guest as a systemd credential. gatus's push API is
          reachable through the public caddy too, so this token is all that
          keeps anyone else from writing results. Delete it and restart
          gatus-provision-secrets and microvm@gatus to rotate it.
        '';
      };
    };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (infraLib.mkGuest config {
        name = "gatus";
        inherit cfg;
        module = import ../../guests/gatus.nix {
          proxyAddress = caddy.address;
          endpoints = [ headscaleEndpoint ] ++ tailnetEndpoints ++ cfg.endpoints;
          externalEndpoints = microvmEndpoints;
          # Names the checks above use that must resolve over the bridge
          # rather than through public DNS.
          hosts = {
            ${caddy.address} = [ headscale.tlsHostname ];
          }
          // lib.optionalAttrs (caddyInternal.enable && caddyInternal.virtualHosts != { }) {
            ${caddyInternal.address} = map (label: "${label}.${headscale.baseDomain}") (
              lib.attrNames caddyInternal.virtualHosts
            );
          };
        };
        credentialFiles.gatus-push-token = cfg.pushTokenFile;
      })

      (infraLib.provisionSecrets {
        vm = "gatus";
        description = "Generate the gatus guest's push token";
        path = [
          pkgs.openssl
          pkgs.coreutils
        ];
        secrets.${cfg.pushTokenFile} = ''
          openssl rand -hex 32 > "$f"
        '';
      })

      (lib.mkIf (cfg.microvms != [ ]) {
        # Pushes each microvm@ unit's state to its external endpoint, over
        # the bridge (the guest opens its port to the host for this). Every
        # minute, a fifth of the heartbeat above. A failed push — gatus down
        # or still booting — fails the run, and the next one tries again.
        systemd.services.gatus-push-microvms = {
          description = "Push the microVMs' systemd state to the gatus status page";
          after = [ "gatus-provision-secrets.service" ];
          path = [
            pkgs.curl
            config.systemd.package
          ];
          serviceConfig = {
            Type = "oneshot";
            DynamicUser = true;
            LoadCredential = [ "push-token:${cfg.pushTokenFile}" ];
          };
          script = ''
            token=$(< "$CREDENTIALS_DIRECTORY/push-token")
            rc=0

            # push <key> <curl args...>. The token goes in as a header file,
            # never on curl's command line.
            push() {
              local key=$1
              shift
              curl --silent --show-error --fail --max-time 10 --get --request POST \
                --header @<(printf 'Authorization: Bearer %s\n' "$token") \
                "$@" "http://${cfg.address}:${toString webPort}/api/v1/endpoints/$key/external" \
                >/dev/null || rc=1
            }

          ''
          + lib.concatMapStrings (vm: ''
            state=$(systemctl is-active ${lib.escapeShellArg "microvm@${vm}.service"} || true)
            if [ "$state" = active ]; then
              push ${gatusKey microvmGroup vm} --data-urlencode success=true
            else
              push ${gatusKey microvmGroup vm} --data-urlencode success=false \
                --data-urlencode "error=unit is $state"
            fi
          '') cfg.microvms
          + ''

            exit "$rc"
          '';
        };

        systemd.timers.gatus-push-microvms = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "1m";
            OnUnitActiveSec = "1m";
            AccuracySec = "5s";
          };
        };
      })

      {
        assertions = [
          {
            assertion = caddy.enable;
            message = "qt1.infra.guests.gatus requires qt1.infra.guests.caddy.enable — the WAN-facing proxy is the status page's only way in.";
          }
        ];

        qt1.infra.guests.caddy.virtualHosts.${cfg.hostname} = "${cfg.address}:${toString webPort}";

        # Opens caddy-internal's 443 to this guest, for the tailnet checks
        # above. Only does anything when caddy-internal is itself enabled.
        qt1.infra.guests.caddyInternal.probesFromGatus = true;
      }
    ]
  );
}
