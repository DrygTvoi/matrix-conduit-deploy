# Matrix Conduit — Self-Hosted Server

A one-click deployment of a fully-featured [Matrix](https://matrix.org/) homeserver using [Conduit](https://conduit.rs/), with integrated voice/video calling via [LiveKit](https://livekit.io/) and [Element Call](https://call.element.io/).

## What you get

| Service | Purpose |
|---|---|
| **Conduit** | Federated Matrix homeserver |
| **Element Call** | Browser-based voice/video client |
| **LiveKit** | WebRTC media server (SFU) |
| **coTURN** | TURN/STUN server for NAT traversal |
| **Caddy** | Reverse proxy with automatic HTTPS |

## Requirements

- A Linux server with a public IP address
- [Docker](https://docs.docker.com/engine/install/) with [Compose](https://docs.docker.com/compose/install/) plugin
- A domain name with the ability to manage DNS records
- Ports `80`, `443`, `3478`, `5349` open in your firewall, plus UDP ranges `49160–49200` and `50000–50100`

## Quick Start

```bash
git clone https://github.com/your-username/matrix-conduit-deploy.git
cd matrix-conduit-deploy
bash setup.sh
```

The script will guide you through everything interactively.

## DNS Records

Before running the server you need to point **4 subdomains** to your server IP:

| Subdomain | Purpose |
|---|---|
| `example.com` | Matrix homeserver |
| `call.example.com` | Element Call client |
| `sfu.example.com` | LiveKit SFU |
| `turn.example.com` | TURN/STUN server |

The setup script will print the exact table with your domain and IP filled in.

## Firewall / Ports

| Port | Protocol | Service |
|---|---|---|
| 80 | TCP | HTTP (Caddy ACME redirect) |
| 443 | TCP | HTTPS |
| 3478 | UDP + TCP | TURN |
| 5349 | TCP | TURN over TLS |
| 49160–49200 | UDP | LiveKit WebRTC media |
| 50000–50100 | UDP | TURN relay |

## After Setup

### Connect a Matrix client

Any Matrix-compatible client works: [Element](https://element.io/), [FluffyChat](https://fluffychat.im/), [Cinny](https://cinny.in/), etc.

Set your homeserver to `https://your-domain.com` and register using the token printed by the setup script.

### Voice/Video calls

Open `https://call.your-domain.com` in a browser. Sign in with your Matrix account.

### Useful commands

```bash
# View all logs
docker compose logs -f

# View logs for a specific service
docker compose logs -f conduit

# Stop everything
docker compose down

# Update images and restart
docker compose pull && docker compose up -d
```

## Re-run setup

If you want to change settings (new domain, new IP, etc.), simply run `setup.sh` again — it will overwrite all generated config files.

## Architecture

```
Internet
   │
   ▼
Caddy (HTTPS + routing)
   ├── example.com         → Conduit (Matrix API + well-known)
   ├── call.example.com    → Element Call + turn-config (TURN credentials)
   └── sfu.example.com     → LiveKit + lk-jwt

coTURN ← used by both LiveKit and Matrix clients for WebRTC NAT traversal
```

## License

MIT — see [LICENSE](LICENSE).
