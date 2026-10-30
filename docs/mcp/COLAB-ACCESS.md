# Remote MCP access from Windows and Google Colab

The OVH platform now includes Tailscale and Tailscale Serve **inside the default Docker Compose deployment**. Do not install Tailscale on the OVH Ubuntu host and do not run host-level `tailscale serve` commands.

For the server deployment and tailnet policy, see [DOCKER-TAILSCALE-STUDENT-LAB.md](DOCKER-TAILSCALE-STUDENT-LAB.md).

## 1. Endpoints

After deployment, inspect the actual tailnet FQDN:

```bash
docker compose exec tailscale tailscale status
docker compose exec tailscale tailscale serve status
```

The default hostname pattern is:

- Spark MCP: `https://spark-lakehouse-agent.<tailnet>.ts.net/spark/mcp`
- MinIO MCP: `https://spark-lakehouse-agent.<tailnet>.ts.net/minio/mcp`

Replace `<tailnet>` with the real MagicDNS suffix. Both endpoints use HTTPS TCP 443.

## 2. Windows, macOS and Linux

Install the official Tailscale client on the student's operating system and sign in with an individually authorized tailnet identity:

- [Windows](https://tailscale.com/download/windows)
- [macOS](https://tailscale.com/download/mac)
- [Linux](https://tailscale.com/download/linux)

Ensure the device is connected and MagicDNS is enabled. Configure the MCP-compatible client with the endpoint URLs above. Do not use the server's Tailscale auth key on student devices.

## 3. Google Colab

Colab does not inherit the local computer's Tailscale connection. Use the notebook [01_colab_private_mcp_validation.ipynb](../../notebooks/01_colab_private_mcp_validation.ipynb). It starts an ephemeral userspace Tailscale node with a SOCKS5 proxy in the Colab runtime.

1. Create an **ephemeral** auth key for a dedicated Colab tag (for example `tag:colab`).
2. Configure a tailnet grant allowing that tag to reach the platform node on TCP 443 only.
3. Store the key in Colab Secrets under `TS_AUTHKEY`; never hard-code it in the notebook.
4. Run the notebook cells to start Tailscale userspace networking and verify DNS/TLS/MCP initialize.

Use these endpoint constants in the notebook/client:

```python
SPARK_MCP_URL = "https://spark-lakehouse-agent.<tailnet>.ts.net/spark/mcp"
MINIO_MCP_URL = "https://spark-lakehouse-agent.<tailnet>.ts.net/minio/mcp"
```

The MCP SDK transport must explicitly support the local SOCKS5 proxy at `127.0.0.1:1055`. Use `socks5h` semantics so DNS is resolved through the proxy. Do not disable TLS certificate verification.

## 4. MCP HTTP negotiation

Streamable HTTP POST requests must include:

```http
Content-Type: application/json
Accept: application/json, text/event-stream
```

Standalone SSE GET requests must include `Accept: text/event-stream`. A plain browser GET or HTTP 405 does not validate the MCP initialize flow. Test with initialize followed by tools/list.

## 5. Security

- The OVH MCP endpoints are private tailnet routes, not public Internet services.
- Tailscale Serve is configured with Funnel disabled.
- Do not expose the public OVH ports 8002/8003.
- Keep the server auth key in the server's untracked `.env`; keep the Colab ephemeral key in Colab Secrets.
- Tailnet ACLs do not provide per-student Spark session, row-level, bucket, or tool isolation. Do not expose sensitive data or enable writes until team-level authorization is implemented.

## Official references

- [Tailscale userspace networking](https://tailscale.com/docs/concepts/userspace-networking)
- [Tailscale Docker configuration](https://tailscale.com/docs/features/containers/docker/docker-params)
- [Tailscale Serve](https://tailscale.com/docs/features/tailscale-serve)
- [Tailscale auth keys](https://tailscale.com/kb/1085/auth-keys)
