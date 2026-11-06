# NixOS module for the rayfish daemon.
#
# The daemon owns /etc/rayfish and /var/lib/rayfish as mutable state:
# settings.toml and networks/<name>.toml mix operator configuration with
# runtime state (rosters, pending joins, certificates) and are rewritten
# atomically by the daemon. Writing those files from the Nix store would be
# clobbered on the first daemon write, so this module converges declarative
# configuration through the daemon's own CLI/IPC surface after startup.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.rayfish;
  yamlFormat = pkgs.formats.yaml { };
  ray = lib.getExe cfg.package;

  onOff = b: if b then "on" else "off";

  renderSetting =
    value:
    if lib.isBool value then
      onOff value
    else if lib.isList value then
      lib.concatStringsSep "," value
    else
      toString value;

  configSetLines = lib.mapAttrsToList (
    key: value:
    let
      rendered = renderSetting value;
      replace = lib.optionalString (lib.isList value) " --replace";
    in
    "${ray} config set ${lib.escapeShellArg key} ${lib.escapeShellArg rendered}${replace}"
  ) cfg.settings;

  settingsGeneration = builtins.hashString "sha256" (
    builtins.toJSON {
      inherit (cfg) settings operator;
    }
  );

  wantSettingsUnit = cfg.operator != null || cfg.settings != { };

  # Effective apply spec file: an explicit specFile wins over rendered attrs.
  applySpecFile =
    if cfg.apply.specFile != null then
      cfg.apply.specFile
    else if cfg.apply.spec != null then
      # `ray apply` rejects anything not named *.yaml/*.yml.
      yamlFormat.generate "rayfish-apply.yaml" cfg.apply.spec
    else
      null;

  waitReady = ''
    wait_ready() {
      local i
      for i in $(seq 60); do
        ${ray} config get >/dev/null 2>&1 && return 0
        sleep 1
      done
      echo "rayfish daemon did not become ready" >&2
      return 1
    }
  '';

  joinCalls = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      name: net:
      "${lib.concatStringsSep " " [
        "join_network"
        (lib.escapeShellArg name)
        (lib.escapeShellArg net.keyFile)
        (lib.escapeShellArg (if net.hostname == null then "" else net.hostname))
        (if net.autoAcceptFirewall then "true" else "false")
        (if net.autoAcceptFiles then "true" else "false")
      ]}"
    ) cfg.networks
  );

  applyNetworkNames = if cfg.apply.spec == null then [ ] else builtins.attrNames (cfg.apply.spec.networks or { });
  overlappingNetworks = builtins.filter (name: builtins.hasAttr name cfg.networks) applyNetworkNames;
in
{
  options.services.rayfish = {
    enable = lib.mkEnableOption "rayfish P2P mesh VPN daemon";

    package = lib.mkPackageOption pkgs "rayfish" { };

    operator = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "alice";
      description = ''
        Unprivileged user authorized for mutating `ray` commands (the
        Tailscale operator model). Applied at runtime with `ray set-operator`;
        reads are open to any local user that can reach the IPC socket.
      '';
    };

    logLevel = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "rayfish=trace";
      description = ''
        `RUST_LOG` filter for the daemon. When unset the daemon uses its own
        defaults: console `info` and rolling file logs at `rayfish=debug`.
      '';
    };

    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra command-line arguments passed to `ray daemon`.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Trust Rayfish's TUN interface and open its underlay UDP port in the
        NixOS firewall. Rayfish has its own per-peer firewall, so trusting the
        interface prevents the host firewall from also dropping inbound mesh
        traffic. UDP 41383 is the daemon's fixed QUIC listen port and is needed
        for direct peer connections. The daemon names its Linux interface
        `rayfish0`.
      '';
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.oneOf [
          lib.types.bool
          lib.types.int
          lib.types.str
          (lib.types.listOf lib.types.str)
        ]
      );
      default = { };
      example = lib.literalExpression ''
        {
          relay = [ "n0" ];
          discovery-dns = [ "n0" ];
          dns-upstreams = [ "9.9.9.9" ];
          on-demand = false;
          mdns = true;
          dns = "partial";
          inbound = "known";
        }
      '';
      description = ''
        Global Rayfish settings, applied with `ray config set` after the
        daemon starts. Keys are the names shown by `ray config get`; examples
        include `relay`, `discovery-dns`, `dns-upstreams`, `on-demand`, `mdns`,
        `dns`, `inbound`, `quic-engine`, `ssh`, `ssh-port`, `v4-bridge`,
        `blocked`, `file-auto-accept-peers`, `download-dir`, and
        `download-user`.

        Lists are rendered as comma-separated values and passed with
        `--replace`. Boolean values become `on`/`off`.

        Changing this option (or {option}`services.rayfish.operator`) restarts
        the daemon once so startup-only settings take effect. NixOS rebuilds
        that only change the package do not cause an extra restart.
      '';
    };

    apply = {
      spec = lib.mkOption {
        type = lib.types.nullOr yamlFormat.type;
        default = null;
        example = lib.literalExpression ''
          {
            networks.homelab = {
              server.allows."*" = "tcp:22,tcp:443";
            };
          }
        '';
        description = ''
          Declarative provisioning spec, rendered to YAML and reconciled with
          `ray apply` after the daemon starts. This is coordinator-side: it
          creates missing closed networks and publishes suggested firewall
          rules. It does not join this node to an existing network; use
          {option}`services.rayfish.networks` for that.
        '';
      };

      specFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Path to a ready-made `ray apply` YAML spec (must end in `.yaml` or
          `.yml`). Mutually exclusive with {option}`services.rayfish.apply.spec`.
        '';
      };

      prune = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Pass `--prune` to `ray apply`: drop suggested-firewall subjects that
          are no longer in the spec instead of merging over the live set.
        '';
      };

      inviteMissing = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Pass `--invite-missing` to `ray apply`: mint one-time hostname-bound
          invites for hosts the spec expects but that have not joined yet. The
          invites are printed to the unit's journal.
        '';
      };
    };

    networks = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            keyFile = lib.mkOption {
              type = lib.types.str;
              description = ''
                Path to a file containing a network key or invite code. Use a
                string path on the target system (for example
                `"/run/secrets/rayfish-lab-key"`), not a Nix path literal: a
                path literal would be copied into the world-readable Nix
                store. The file is read by the root service, so it may be
                root-only (for example a sops-nix or agenix secret).
              '';
            };

            hostname = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "server";
              description = ''
                Hostname for this node on the network. When unset, Rayfish
                uses the saved default or the machine hostname.
              '';
            };

            autoAcceptFirewall = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = ''
                Pass `--auto-accept-firewall`: install coordinator-suggested
                firewall rules on this network without manual review.
              '';
            };

            autoAcceptFiles = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = ''
                Accept file offers from this user's own paired devices without
                manual approval. Set to `false` to pass
                `--no-auto-accept-files`.
              '';
            };
          };
        }
      );
      default = { };
      description = ''
        Networks to join on first boot or when this option changes. The
        attribute name is the local network alias (`--name`). Joining is
        one-time: an existing saved network with the same local name is left
        alone, and later removal remains `ray leave`/`ray nuke`.

        The key file is read at service runtime and never enters the Nix
        store.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !(cfg.apply.spec != null && cfg.apply.specFile != null);
        message = "services.rayfish.apply: set either `spec` or `specFile`, not both.";
      }
      {
        assertion = overlappingNetworks == [ ];
        message = "services.rayfish: networks ${builtins.concatStringsSep ", " overlappingNetworks} are declared in both `apply.spec.networks` and `networks`; `ray apply` creates networks while `networks` joins them.";
      }
    ];

    warnings =
      lib.optional (!config.services.resolved.enable) ''
        services.rayfish: systemd-resolved is not enabled. Rayfish will fall
        back to NetworkManager/resolvconf or, as a last resort, take over
        /etc/resolv.conf directly for Magic DNS, which fights NixOS's
        declarative resolv.conf management. Set services.resolved.enable = true.
      ''
      ++ lib.optional ((cfg.settings ? "auto-update") && cfg.settings."auto-update" == true) ''
        services.rayfish: `settings.auto-update` is incompatible with NixOS
        because the store is read-only. Keep auto-update off and update the
        flake input instead.
      '';

    users.groups.rayfish = { };

    boot.kernelModules = [ "tun" ];

    networking.firewall.trustedInterfaces = lib.mkIf cfg.openFirewall [ "rayfish0" ];
    # RAYFISH_LISTEN_PORT in upstream src/transport.rs. Needed for direct
    # inbound QUIC; the relay fallback is not available on every network.
    networking.firewall.allowedUDPPorts = lib.mkIf cfg.openFirewall [ 41383 ];

    environment.systemPackages = [ cfg.package ];

    systemd.services.rayfish = {
      description = "rayfish P2P mesh VPN";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "systemd-resolved.service"
      ];
      wants = [ "network-online.target" ];
      # ip/nft for exit nodes and route inspection; systemd for resolvectl.
      path = [
        pkgs.iproute2
        pkgs.nftables
        config.systemd.package
      ];
      environment = lib.optionalAttrs (cfg.logLevel != null) { RUST_LOG = cfg.logLevel; };
      serviceConfig = {
        ExecStart = "${ray} daemon ${lib.escapeShellArgs cfg.extraFlags}";
        # Undo DNS and exit-node changes when the daemon died without its own
        # teardown. A leading "-" keeps a failed cleanup from failing the unit.
        ExecStopPost = "-${ray} daemon --cleanup";
        Restart = "on-failure";
        RestartSec = 5;
        TimeoutStopSec = 20;
        RuntimeDirectory = "rayfish";
      };
    };

    # Post-start convergence for operator and global settings.
    systemd.services.rayfish-settings = lib.mkIf wantSettingsUnit {
      description = "rayfish declarative settings";
      wantedBy = [ "multi-user.target" ];
      # Wants, not Requires: this unit restarts rayfish.service below.
      after = [ "rayfish.service" ];
      wants = [ "rayfish.service" ];
      path = [
        pkgs.coreutils
        config.systemd.package
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        StateDirectory = "rayfish-nixos";
        StateDirectoryMode = "0700";
      };
      script = ''
        set -euo pipefail
        ${waitReady}
        wait_ready

        ${lib.optionalString (cfg.operator != null) "${ray} set-operator ${lib.escapeShellArg cfg.operator}"}
        ${lib.concatStringsSep "\n" configSetLines}

        stamp=/var/lib/rayfish-nixos/settings-generation
        want=${settingsGeneration}
        if [ "$(cat "$stamp" 2>/dev/null || true)" != "$want" ]; then
          # Restart once per desired-state change so settings only read at
          # startup take effect. Package-only rebuilds keep the stamp.
          systemctl restart rayfish.service
          wait_ready
          printf '%s\n' "$want" > "$stamp"
        fi
      '';
    };

    # Declarative one-shot reconcile of coordinator networks and rules.
    systemd.services.rayfish-apply = lib.mkIf (applySpecFile != null) {
      description = "rayfish declarative network reconcile (ray apply)";
      wantedBy = [ "multi-user.target" ];
      after = [ "rayfish.service" ] ++ lib.optional wantSettingsUnit "rayfish-settings.service";
      wants = [ "rayfish.service" ];
      path = [ pkgs.coreutils ];
      restartTriggers = [ applySpecFile ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail
        ${waitReady}
        wait_ready
        ${ray} apply ${lib.escapeShellArg (toString applySpecFile)} ${
          lib.optionalString cfg.apply.prune "--prune"
        } ${lib.optionalString cfg.apply.inviteMissing "--invite-missing"}
      '';
    };

    # Declarative network joins, one-time per local network name.
    systemd.services.rayfish-join = lib.mkIf (cfg.networks != { }) {
      description = "rayfish declarative network joins";
      wantedBy = [ "multi-user.target" ];
      after = [ "rayfish.service" ] ++ lib.optional wantSettingsUnit "rayfish-settings.service";
      wants = [ "rayfish.service" ];
      path = [
        pkgs.coreutils
        pkgs.jq
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail
        ${waitReady}

        join_network() {
          local name="$1" keyfile="$2" hostname="$3"
          local auto_accept_firewall="$4" auto_accept_files="$5"

          if ${ray} status --json \
            | ${pkgs.jq}/bin/jq -e \
              --arg name "$name" \
              '([.networks[]?.name, .inactive_networks[]?.name] | index($name)) != null' \
              >/dev/null 2>&1; then
            echo "rayfish: network '$name' is already saved"
            return 0
          fi

          local i
          for i in $(seq 60); do
            [ -r "$keyfile" ] && break
            sleep 1
          done
          if [ ! -r "$keyfile" ]; then
            echo "rayfish: key file for network '$name' not found: $keyfile" >&2
            return 1
          fi

          local args=(--name "$name")
          [ -n "$hostname" ] && args+=(--hostname "$hostname")
          [ "$auto_accept_firewall" = "true" ] && args+=(--auto-accept-firewall)
          [ "$auto_accept_files" = "false" ] && args+=(--no-auto-accept-files)

          ${ray} join "$(cat "$keyfile")" "''${args[@]}"
        }

        wait_ready
        ${joinCalls}
      '';
    };
  };
}
