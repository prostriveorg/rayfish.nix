# Boot-tests the NixOS module offline: daemon up, IPC socket, declarative
# settings converged, `ray apply` reconciled a network, and the operator model
# works. Joining a network is not tested here because it needs a reachable
# coordinator or discovery service.
{ rayfishModule }:
{
  name = "rayfish";

  nodes.machine =
    { ... }:
    {
      imports = [ rayfishModule ];

      services.resolved.enable = true;
      users.users.alice = {
        isNormalUser = true;
        password = "";
      };

      services.rayfish = {
        enable = true;
        operator = "alice";
        settings = {
          dns-upstreams = [ "9.9.9.9" ];
        };
        apply.spec.networks.ci-net = { };
      };

      virtualisation.cores = 2;
      virtualisation.memorySize = 2048;
    };

  testScript = ''
    machine.wait_for_unit("rayfish.service")
    machine.wait_until_succeeds("test -S /run/rayfish/rayfish.sock", timeout=90)
    # `ray config get` is an IPC round-trip, so it proves the daemon is ready.
    machine.wait_until_succeeds("ray config get", timeout=90)

    # Settings oneshot converged, including its one settings-triggered restart.
    machine.wait_for_unit("rayfish-settings.service")
    machine.succeed("ray config get dns-upstreams | grep -F 9.9.9.9")

    # Apply oneshot created the declared coordinator network.
    machine.wait_for_unit("rayfish-apply.service")
    machine.wait_until_succeeds("ray status | grep -F ci-net", timeout=60)

    # The overlay is IPv6-only; the daemon routes 200::/7 through its TUN.
    machine.wait_until_succeeds("ip -6 route show | grep -E '^200::/7 '", timeout=60)

    # Operator model: alice may run mutating commands without root.
    machine.succeed("su - alice -c 'ray mdns off'")
  '';
}
