# Secure remote MCP access with Tailscale

This guide exposes **only** the Spark MCP and MinIO MCP HTTP endpoints to authenticated devices in your Tailscale tailnet. It does not publish the services to the public Internet.

## Why Tailscale instead of a public IP?

The Compose deployment deliberately binds MCP host ports to `127.0.0.1`. Keep that protection. A public IP returned by an outbound IP-check service may be a NAT gateway address, may be shared through carrier-grade NAT (CGNAT), and does not prove that inbound connections can reach this host.

Tailscale Serve provides HTTPS endpoints inside your private tailnet while proxying to the existing loopback-only services. No Docker port-binding changes, router port forwarding, or public firewall openings are required.

## 1. Install and connect Tailscale

Install Tailscale on the Ubuntu host and on each authorized agent/client machine, then sign both into the same tailnet. Follow the official installation guide for your operating system:

- https://tailscale.com/download
- https://tailscale.com/kb/1017/install

On Ubuntu, confirm the host is connected:

```bash
tailscale status
tailscale ip -4
```

Enable HTTPS certificates for your tailnet if prompted by Tailscale Serve. Apply tailnet ACL/grant rules so only approved users and devices can reach this host.

## 2. Confirm the local MCP services

From the project directory:

```bash
docker compose ps spark-mcp minio-mcp
curl -sS -o /dev/null -w 'Spark MCP local HTTP: %{http_code}\n' http://127.0.0.1:8002/mcp
curl -sS -o /dev/null -w 'MinIO MCP local HTTP: %{http_code}\n' http://127.0.0.1:8003/mcp
```

An HTTP response (including a protocol-level response such as 4xx for a plain GET) confirms the local listener is reachable; it is not a complete MCP protocol test. Run the project validation script for service integration checks:

```bash
sudo ./scripts/validate.sh
```

## 3. Publish the two MCP endpoints inside the tailnet

The following uses two HTTPS listener ports on the same Tailscale DNS name. The backends remain bound to loopback:

```bash
sudo tailscale serve --bg --https=443 127.0.0.1:8002
sudo tailscale serve --bg --https=8443 127.0.0.1:8003
sudo tailscale serve status
```

Tailscale Serve should report the HTTPS DNS name for this machine. Use that exact name in the agent configuration; do not guess it.

- Spark MCP: `https://<your-tailscale-dns-name>/mcp`
- MinIO MCP: `https://<your-tailscale-dns-name>:8443/mcp`

These URLs are reachable only by authorized devices in the tailnet. Do **not** use Tailscale Funnel for these data-access services.

## 4. Configure the remote MCP client

Example Streamable HTTP configuration (adapt the schema to your MCP client):

```json
{
  "mcpServers": {
    "spark-lakehouse": {
      "type": "http",
      "url": "https://<your-tailscale-dns-name>/mcp"
    },
    "minio-lakehouse": {
      "type": "http",
      "url": "https://<your-tailscale-dns-name>:8443/mcp"
    }
  }
}
```

Replace the placeholder with the DNS name printed by `tailscale serve status`. The remote client must be connected to the same tailnet and permitted by its access policy.

## 5. Verify from a second tailnet device

On the remote client:

```bash
curl -i https://<your-tailscale-dns-name>/mcp
curl -i https://<your-tailscale-dns-name>:8443/mcp
```

A plain GET may not complete the MCP handshake; use your MCP client's Streamable HTTP connection/initialize flow to verify protocol interoperability. Also verify that a device outside the tailnet cannot reach these endpoints.

## 6. Disable remote access

To remove only these two Serve listeners:

```bash
sudo tailscale serve --https=443 127.0.0.1:8002 off
sudo tailscale serve --https=8443 127.0.0.1:8003 off
sudo tailscale serve status
```

To remove all Serve configuration from this host instead, use `sudo tailscale serve reset` (this also removes any other Serve routes configured on the host).

## Security notes

- Keep the Docker Compose MCP bindings on `127.0.0.1`; do not replace them with `0.0.0.0` for this setup.
- Do not expose JupyterLab, Spark master/worker UIs, MinIO API/console, Ollama, or Spark RPC through Tailscale Serve.
- Do not enable Tailscale Funnel or create public router port-forwarding rules for these MCP services.
- Restrict tailnet access with least-privilege ACLs/grants and use dedicated MinIO MCP credentials with the narrowest required bucket permissions. MinIO MCP writes remain disabled by default.
- Tailscale Serve provides encrypted transport and tailnet-level access control. It does not add application-level MCP user authorization or per-tool approval. Treat all authorized tailnet devices as trusted to invoke the MCP tools exposed to them.
- Keep credentials in the host's untracked `.env`; never commit them.

## References

- Tailscale Serve overview: https://tailscale.com/docs/features/tailscale-serve
- Tailscale Serve CLI reference: https://tailscale.com/docs/reference/tailscale-cli/serve
