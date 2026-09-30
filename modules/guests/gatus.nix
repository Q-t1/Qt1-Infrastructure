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

  # The page is public; errors leak addresses too (`dial tcp 10.100.0.5:443`).
  hideInternals = {
    hide-hostname = true;
    hide-url = true;
    hide-port = true;
    hide-errors = true;
  };

  headscaleEndpoint = {
    name = "Headscale";
    group = "Public";
    url = "https://${headscale.tlsHostname}/health";
    interval = "1m";
    conditions = [
      "[STATUS] == 200"
      "[BODY].status == pass"
      # Caddy renews at a third of the lifetime left; under a week means renewal is failing.
      "[CERTIFICATE_EXPIRATION] > 168h"
    ];
    ui = hideInternals;
  };

  tailnetEndpoints = lib.mapAttrsToList (label: url: {
    name = label;
    group = "Tailnet";
    inherit url;
    interval = "1m";
    # Signed by caddy-internal's runtime local CA, which this guest has no copy of.
    client.insecure = true;
    conditions = [ "[STATUS] < 400" ];
    ui = hideInternals;
  }) (lib.optionalAttrs caddyInternal.enable caddyInternal.urls);

  microvmGroup = "MicroVMs";
  microvmEndpoints = map (vm: {
    name = vm;
    group = microvmGroup;
    token = "\${GATUS_PUSH_TOKEN}";
    heartbeat.interval = "5m";
  }) cfg.microvms;

  # `<group>_<name>`, the push API's address. Must match gatus's
  # key.sanitize (config/key/key.go).
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

            # Token via a header file, never on curl's command line.
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
        qt1.infra.guests.caddyInternal.probesFromGatus = true;
      }
    ]
  );
}
