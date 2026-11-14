# rayfish.nix

A Nix flake that packages [Rayfish](https://github.com/rayfish/rayfish) and
provides a NixOS module for running and configuring its daemon.

Rayfish is a peer-to-peer mesh VPN over iroh. It is currently experimental
upstream, so treat this packaging as experimental too.

## Usage

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    rayfish.url = "github:your-name/rayfish.nix";
  };

  outputs = { nixpkgs, rayfish, ... }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        rayfish.nixosModules.default
        {
          services.rayfish = {
            enable = true;
            operator = "alice";

            settings = {
              on-demand = false;
              dns-upstreams = [ "9.9.9.9" ];
            };

            # Coordinator-side declarative provisioning. This creates missing
            # networks and publishes firewall suggestions; it does not join
            # this node to an existing network.
            apply.spec.networks.homelab = {
              server.allows."*" = "tcp:22,tcp:443";
            };

            # One-time declarative joins.
            #
            # A public room id can be declared inline; it is not a secret.
            # On a closed network the coordinator still has to admit the node.
            networks.lab = {
              key = "6b08e1159e5c1b8442183c2214385cdf770170e7ccb53c757cd7c9aeae686e82";
              hostname = "server";
            };

            # A secret invite/key must stay out of the Nix store.
            networks.other = {
              keyFile = "/run/secrets/rayfish-other-key";
              hostname = "server-2";
            };
          };
        }
      ];
    };
  };
}
```

`services.rayfish` adds `ray` to `environment.systemPackages`, creates the
`rayfish` group, starts the daemon from `systemd`, and converges the declared
settings through the daemon's own IPC surface.

## Important behavior

- **Rayfish owns `/etc/rayfish` and `/var/lib/rayfish`.** They are mutable
  daemon state and are deliberately not managed as Nix store files. This module
  never writes `settings.toml` or `networks/*.toml`.
- **Settings are applied at runtime.** Changing `services.rayfish.settings` or
  `services.rayfish.operator` restarts the daemon once so startup-only settings
  take effect. Package-only rebuilds leave the daemon running.
- **Joins are one-time.** `services.rayfish.networks.<name>` joins only when the
  local network name is not already saved. Removing a network remains
  `ray leave <name>` or `ray nuke <name>`.
- **Room ids are public; invites/keys are secret.** Use `key` for a network's
  public room id. Use `keyFile` with a string path such as
  `"/run/secrets/rayfish-lab-key"` (sops-nix, agenix, etc.) for a secret invite
  or key. Do not use a Nix path literal for a secret: it would be copied into
  the world-readable store. The service runs as root, so the file may be
  root-only. Set exactly one of `key` or `keyFile` per network.
- **A room-id join on a closed network is pending** until a coordinator admits
  it (`ray requests <network>` then `ray requests <network> accept <id>`). A
  hostname-bound invite can admit without that manual step.
- **Do not overlap `networks` and `apply.spec.networks`.** `ray apply` creates
  coordinator networks; `networks` joins existing ones. The module rejects an
  overlap when the spec is supplied inline.
- **Enable systemd-resolved.** Rayfish prefers systemd-resolved's D-Bus split
  DNS path. Without it, Rayfish may take over `/etc/resolv.conf`, which fights
  NixOS's declarative DNS management. The module emits a warning when
  `services.resolved.enable` is false.
- **Keep auto-update off.** The Nix store is read-only. Update the flake input
  instead of setting `services.rayfish.settings.auto-update = true`.

## Options

| Option | Description |
| --- | --- |
| `services.rayfish.enable` | Enable the daemon and boot integration. |
| `services.rayfish.package` | Package to use; defaults to this flake's build. |
| `services.rayfish.operator` | Unprivileged user allowed to run mutating `ray` commands. |
| `services.rayfish.logLevel` | `RUST_LOG` filter for the daemon. |
| `services.rayfish.extraFlags` | Extra arguments passed to `ray daemon`. |
| `services.rayfish.openFirewall` | Trust `rayfish0` and open UDP 41383 in the NixOS firewall. |
| `services.rayfish.settings` | Global settings applied with `ray config set`. |
| `services.rayfish.apply.spec` | Inline `ray apply` YAML spec (as a Nix attrset). |
| `services.rayfish.apply.specFile` | Path to an existing `ray apply` YAML spec. |
| `services.rayfish.apply.prune` | Pass `--prune` to `ray apply`. |
| `services.rayfish.apply.inviteMissing` | Pass `--invite-missing` to `ray apply`. |
| `services.rayfish.networks.<name>.key` | Public network room id. |
| `services.rayfish.networks.<name>.keyFile` | Secret file containing a network key or invite code. |
| `services.rayfish.networks.<name>.hostname` | Hostname on the joined network. |
| `services.rayfish.networks.<name>.autoAcceptFirewall` | Auto-install suggested firewall rules. |
| `services.rayfish.networks.<name>.autoAcceptFiles` | Auto-accept files from own paired devices. |

## Development

```bash
nix build .#rayfish
nix flake check
nix build .#checks.x86_64-linux.vm-test
nix build .#checks.x86_64-linux.vm-test-e2e
```

`vm-test` is the quick offline smoke test. `vm-test-e2e` runs a coordinator and
a member with a local pkarr relay and a local iroh relay, creates a network,
performs the declarative join, checks the mesh roster, and pings the
coordinator through Magic DNS.

The package is built from the upstream source pinned by the `rayfish-src`
flake input. To upgrade, change the tag in `flake.nix`, run `nix flake update
rayfish-src`, and rebuild.

Upstream pins several dependencies to git forks. When those revs change, update
the `outputHashes` in `nix/package.nix` by replacing the affected values with
`lib.fakeHash`, building, and copying the expected hash from the error.

The end-to-end test also builds `iroh-relay` from the `iroh-src` flake input,
which is pinned to the same `rayfish/iroh` revision as Rayfish's `Cargo.toml`.
Keep that revision in sync when upgrading Rayfish, and refresh the
`outputHashes` in `nix/iroh-relay.nix` if its lockfile's git rev changes.
