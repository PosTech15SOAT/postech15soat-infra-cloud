"""Local Docker integration: real templates, absent Services, then DNS recovery."""
import json
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
import urllib.error
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[2]
IMAGE = "nginxinc/nginx-unprivileged:1.28-alpine"


def run(*args, input=None):
    return subprocess.run(args, input=input, text=True, capture_output=True, check=True).stdout.strip()


class NginxStartupTest(unittest.TestCase):
    def test_absent_services_and_forwarding_after_dns_registration(self):
        network = "numberone-test-" + uuid.uuid4().hex[:10]
        containers = []
        run("docker", "network", "create", network)
        try:
            with tempfile.TemporaryDirectory() as directory:
                temp = Path(directory)
                for name, port in (("gateway", 18080), ("os-identity", 18443)):
                    config_dir = temp / name
                    config_dir.mkdir()
                    variables = {"port": port, "vpc_link_subnets": ["0.0.0.0/0"], "routes": {
                        "POST:/api/admin/clientes": "os",
                        "GET:/api/admin/itens": "inventory",
                        "GET:/css/budget\\.css": "billing",
                        "POST:/api/public/pagamentos/notificacoes/mercado-pago": "billing",
                    }}
                    expression = f'jsonencode(templatefile({json.dumps(str(ROOT / "infra" / (name + "-proxy.conf.tftpl")))}, jsondecode({json.dumps(json.dumps(variables))})))'
                    rendered = run("terraform", f"-chdir={directory}", "console", input=expression)
                    (config_dir / "gateway.conf").write_text(json.loads(json.loads(rendered)))
                    # Execute the chart's actual startup script.
                    chart = (ROOT / "infra/charts/gateway-proxy/templates/daemonset.yaml").read_text()
                    startup = chart.split("            - |\n", 1)[1].split("          ports:", 1)[0]
                    startup = "\n".join(line[14:] for line in startup.splitlines())
                    container = run("docker", "run", "-d", "--read-only", "--tmpfs", "/tmp:uid=101,gid=101", "--cap-drop=ALL",
                                    "--network", network, "-p", f"127.0.0.1::{port}", "-v", f"{config_dir}:/etc/nginx/conf.d:ro",
                                    "--entrypoint", "/bin/sh", IMAGE, "-ec", startup)
                    containers.append(container)
                urls = []
                for container, port in zip(containers, (18080, 18443)):
                    address = run("docker", "port", container, str(port)).splitlines()[0]
                    urls.append("http://" + address)
                gateway, identity = urls

                def request(origin, path, method="GET", body=None, headers=None):
                    req = urllib.request.Request(origin + path, data=body, method=method, headers=headers or {})
                    try:
                        with urllib.request.urlopen(req, timeout=3) as response:
                            return response.status, response.read()
                    except urllib.error.HTTPError as error:
                        return error.code, error.read()

                time.sleep(1)
                self.assertEqual(request(identity, "/wrong")[0], 404)
                self.assertEqual(request(identity, "/internal/auth/customer-identity")[0], 405)
                self.assertEqual(request(identity, "/internal/auth/customer-identity", "POST", b"{}")[0], 502)
                self.assertEqual(request(gateway, "/css/budget.css")[0], 502)
                for container in containers:
                    self.assertEqual(run("docker", "inspect", "--format", "{{.State.Running}}", container), "true")

                backend = '''from http.server import BaseHTTPRequestHandler, HTTPServer
import json
class Handler(BaseHTTPRequestHandler):
 def do_GET(self):
  body = self.rfile.read(int(self.headers.get('Content-Length', '0'))).decode()
  data = json.dumps(dict(path=self.path, method=self.command, headers=dict(self.headers), body=body)).encode()
  self.send_response(200); self.end_headers(); self.wfile.write(data)
 do_POST = do_GET
HTTPServer(('0.0.0.0', 8080), Handler).serve_forever()
'''
                aliases = []
                for service in ("os", "billing", "inventory"):
                    aliases += ["--network-alias", f"numberone-{service}-service.numberone-{service}.svc.cluster.local"]
                containers.append(run("docker", "run", "-d", "--network", network, *aliases, "python:3.12-alpine", "python", "-u", "-c", backend))
                deadline = time.monotonic() + 45
                while time.monotonic() < deadline:
                    if request(gateway, "/css/budget.css")[0] == 200 and request(identity, "/internal/auth/customer-identity", "POST", b"{}")[0] == 200:
                        break
                    time.sleep(1)
                for path, method, origin in (("/css/budget.css?q=1", "GET", gateway), ("/api/admin/itens", "GET", gateway),
                                              ("/api/admin/clientes", "POST", gateway), ("/internal/auth/customer-identity?q=1", "POST", identity),
                                              ("/api/public/pagamentos/notificacoes/mercado-pago?data.id=1", "POST", gateway)):
                    headers = {"Authorization": "Bearer should-be-filtered", "Content-Type": "application/json", "X-Correlation-Id": "test", "X-Signature": "hmac"}
                    status, body = request(origin, path, method, b'{"test":true}', headers)
                    self.assertEqual(status, 200)
                    data = json.loads(body)
                    self.assertEqual((data["path"], data["method"], data["body"]), (path, method, '{"test":true}'))
                    self.assertEqual(data["headers"]["X-Correlation-Id"], "test")
                    if origin == identity:
                        self.assertEqual(data["headers"]["Host"], "numberone-os-service.numberone-os.svc.cluster.local:8080")
                    if origin == identity or "/api/public/" in path:
                        self.assertNotIn("Authorization", data["headers"])
                    if "/pagamentos/" in path:
                        self.assertEqual(data["headers"]["X-Signature"], "hmac")
                self.assertEqual(request(gateway, "/internal/auth/customer-identity", "POST")[0], 404)
                self.assertEqual(request(identity, "/internal/auth/customer-identity/extra", "POST")[0], 404)
                self.assertEqual(request(identity, "/internal/auth/customer-identity", "PUT")[0], 405)
                for path in ("/internal//auth/customer-identity", "/internal/auth/%63ustomer-identity", "/internal/auth/../auth/customer-identity"):
                    self.assertEqual(request(identity, path, "POST")[0], 404)
        finally:
            for container in reversed(containers):
                run("docker", "rm", "-f", container)
            run("docker", "network", "rm", network)


if __name__ == "__main__":
    unittest.main()
