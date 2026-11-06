# End-to-end NixOS test for the module's declarative join path.
#
# The test is hermetic: instead of the public pkarr discovery service it runs a
# tiny local HTTP pkarr relay on the coordinator node. Both daemons publish and
# resolve records through that relay, then connect directly over the test VLAN.
{ rayfishModule, pkgs, irohSrc }:

let
  relayPort = 8080;
  irohRelayPort = 3340;

  irohRelay = pkgs.callPackage ./iroh-relay.nix { src = irohSrc; };
  irohRelayConfig = pkgs.writeText "iroh-relay.toml" ''
    http_bind_addr = "0.0.0.0:${toString irohRelayPort}"
  '';

  pkarrRelay = pkgs.writeText "pkarr-relay.py" ''
    import http.server
    import json
    import sys

    records = {}


    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def _send(self, status, body=b""):
            self.send_response(status)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.close_connection = True
            self.end_headers()
            if body:
                self.wfile.write(body)

        def do_GET(self):
            if self.path == "/__keys":
                self._send(200, json.dumps(sorted(records)).encode())
            elif self.path in records:
                self._send(200, records[self.path])
            else:
                self._send(404)

        def do_PUT(self):
            length = int(self.headers.get("Content-Length", "0"))
            records[self.path] = self.rfile.read(length)
            self._send(200)

        def log_message(self, fmt, *args):
            print(fmt % args, file=sys.stderr)


    http.server.ThreadingHTTPServer(("0.0.0.0", int(sys.argv[1])), Handler).serve_forever()
  '';
in
{
  name = "rayfish-e2e";

  nodes =
    let
      common =
        { pkgs, nodes, ... }:
        {
          imports = [ rayfishModule ];
          services.resolved.enable = true;
          environment.systemPackages = with pkgs; [
            curl
            jq
            iputils
          ];
          services.rayfish = {
            enable = true;
            settings = {
              # The local pkarr relay carries the signed network record. The
              # local iroh relay supplies the addressing information: the
              # default pkarr publisher only publishes relay addresses, and the
              # test runs no public NAT-traversal infrastructure.
              mdns = false;
              discovery-dns = [
                "http://${nodes.coord.networking.primaryIPAddress}:${toString relayPort}/pkarr"
              ];
              relay = [
                "http://${nodes.coord.networking.primaryIPAddress}:${toString irohRelayPort}"
              ];
            };
          };
          virtualisation.cores = 2;
          virtualisation.memorySize = 2048;
        };
    in
    {
      coord =
        { pkgs, ... }:
        {
          imports = [ common ];
          networking.firewall.allowedTCPPorts = [
            relayPort
            irohRelayPort
          ];
          systemd.services.pkarr-relay = {
            description = "local pkarr relay for the rayfish VM test";
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              ExecStart = "${pkgs.python3}/bin/python3 ${pkarrRelay} ${toString relayPort}";
              Restart = "on-failure";
              RestartSec = 1;
            };
          };
          systemd.services.iroh-relay = {
            description = "local iroh relay for the rayfish VM test";
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              ExecStart = "${irohRelay}/bin/iroh-relay --dev --config-path ${irohRelayConfig}";
              Restart = "on-failure";
              RestartSec = 1;
            };
          };
        };

      member =
        { ... }:
        {
          imports = [ common ];
          services.rayfish.networks.e2e = {
            keyFile = "/run/rayfish-e2e-key";
            hostname = "member";
          };
        };
    };

  testScript =
    { nodes, ... }:
    ''
      # Start sequentially: nested-virt hosts take too long to boot both 2 GiB
      # VMs at once, and the test driver's root-shell connect window is finite.
      coord.start()
      coord.wait_for_unit("pkarr-relay.service", timeout=240)
      coord.wait_for_unit("iroh-relay.service", timeout=240)
      member.start()
      coord.wait_for_unit("rayfish-settings.service", timeout=240)
      member.wait_for_unit("rayfish-settings.service", timeout=240)

      coord.wait_until_succeeds(
          "ray config get discovery-dns | grep -F :${toString relayPort}/pkarr",
          timeout=90,
      )
      member.wait_until_succeeds(
          "ray config get discovery-dns | grep -F :${toString relayPort}/pkarr",
          timeout=90,
      )
      coord.wait_until_succeeds(
          "ray config get relay | grep -F :${toString irohRelayPort}",
          timeout=90,
      )
      member.wait_until_succeeds(
          "ray config get relay | grep -F :${toString irohRelayPort}",
          timeout=90,
      )

      # The settings unit converges the discovery config by restarting the
      # daemon. Restart once more here so this test starts from endpoints that
      # were definitely built with the local relay.
      coord.succeed("systemctl restart rayfish.service")
      member.succeed("systemctl restart rayfish.service")
      coord.wait_until_succeeds("ray config get", timeout=90)
      member.wait_until_succeeds("ray config get", timeout=90)

      coord.succeed("ray create --open --name e2e --hostname coord")
      room = coord.succeed(
          "ray status --json | jq -r '.networks[] | select(.name==\"e2e\") | .network_key'"
      ).strip()
      assert room and room != "null", "ray create produced no network key"

      # Wait until the relay has both the network record and the coordinator's
      # endpoint record. `room` is the hex endpoint id, while pkarr stores the
      # z32 form, so inspect the relay's test-only key list rather than
      # constructing the GET path by hand.
      coord.wait_until_succeeds(
          "test $(curl -fsS http://127.0.0.1:${toString relayPort}/__keys | jq length) -ge 2",
          timeout=60,
      )

      # The member's join unit was waiting for this secret file.
      member.succeed(f"printf '%s' '{room}' > /run/rayfish-e2e-key")
      member.wait_until_succeeds(
          "systemctl restart rayfish-join.service 2>/dev/null || true; "
          "ray status --json | jq -e '.networks[] | select(.name==\"e2e\")' >/dev/null",
          timeout=180,
      )
      member.wait_until_succeeds(
          "ray status --json | jq -e '.networks[] | select(.name==\"e2e\") | .peers[]? | select(.hostname==\"coord\")' >/dev/null",
          timeout=120,
      )

      # Reach the coordinator through Magic DNS over the mesh, not the underlay.
      member.wait_until_succeeds("ping -c1 -W2 coord.e2e.ray", timeout=60)

      # Re-running the join unit must be idempotent.
      member.succeed("systemctl restart rayfish-join.service")
      member.succeed(
          "test $(ray status --json | jq '[.networks[] | select(.name==\"e2e\")] | length') -eq 1"
      )

      coord.wait_until_succeeds(
          "ray status --json | jq -e '.networks[] | select(.name==\"e2e\") | .peers[]? | select(.hostname==\"member\")' >/dev/null",
          timeout=120,
      )
    '';
}
