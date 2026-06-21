# Omnisec Deployment Guide

**Version:** 0.2.0  
**Target:** Ubuntu 24.04 LTS (fresh VM)  
**Deployment mode:** Design Partner (safe mode enabled, enforcement logged but not applied)

---

## Overview

Omnisec is a runtime control plane for autonomous AI agents. The design partner deployment runs six services using Docker Compose:

| Service | Image | Port | Role |
|---|---|---|---|
| PostgreSQL | postgres:16-alpine | 5432 | Persistent storage |
| Redis | redis:7-alpine | 6379 | Caching layer |
| NATS | nats:2-alpine | 4222 / 8222 | Event bus (JetStream) |
| omnisec-api | (built locally) | 3000 | REST API + Prometheus |
| omnisec-daemon | (built locally) | — | Orchestration, eBPF sensors |
| omnisec-dashboard | (built locally) | 3002 | Next.js web UI |

All data persists in named Docker volumes (`omnisec_dp_postgres`, `omnisec_dp_nats`).

---

## Part 1: Fresh Ubuntu 24.04 Setup

### 1.1 System update

```bash
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y \
    curl wget git ca-certificates \
    gnupg lsb-release software-properties-common \
    build-essential pkg-config libssl-dev \
    clang llvm linux-tools-common \
    linux-tools-$(uname -r) \
    nftables iproute2 net-tools \
    python3 jq
```

### 1.2 Docker installation

```bash
# Remove any old Docker packages
sudo apt-get remove -y docker docker-engine docker.io containerd runc || true

# Add Docker's official GPG key and repository
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

echo "deb [arch=$(dpkg --print-architecture) \
    signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
    https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Add your user to the docker group (avoids needing sudo for docker commands)
sudo usermod -aG docker "$USER"
newgrp docker

# Verify Docker is running
sudo systemctl enable --now docker
docker --version
docker compose version
```

### 1.3 Rust toolchain (optional — required only for local cargo builds)

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
rustup target add x86_64-unknown-linux-gnu
rustc --version && cargo --version
```

### 1.4 eBPF prerequisites

```bash
# Mount BPF filesystem if not already mounted
sudo mount -t bpf bpffs /sys/fs/bpf 2>/dev/null || true

# Verify BPF filesystem is mounted
ls /sys/fs/bpf

# Make BPF mount persistent across reboots
grep -q bpffs /etc/fstab || echo 'bpffs /sys/fs/bpf bpf defaults 0 0' | sudo tee -a /etc/fstab

# Check kernel BTF availability (required for eBPF CO-RE)
ls /sys/kernel/btf/vmlinux
```

> **Note:** If `/sys/kernel/btf/vmlinux` is missing, the Omnisec daemon will automatically fall back to `/proc`-based polling (1-second resolution). Full eBPF requires kernel 5.8+ with `CONFIG_DEBUG_INFO_BTF=y`.

---

## Part 2: Clone and Configure

### 2.1 Clone the repository

```bash
# If deploying from GitHub (once remote is configured):
git clone <REPO_URL> omnisec
cd omnisec

# Or copy the repository via rsync from your Mac:
# rsync -avz --exclude='.git' /path/to/local/omnisec/ ubuntu@<VM_IP>:~/omnisec/
# On Ubuntu: cd ~/omnisec && git init && git add . && git commit -m "initial"
```

### 2.2 Make scripts executable

```bash
chmod +x scripts/validate-environment.sh
chmod +x scripts/deploy-design-partner.sh
```

### 2.3 Configure environment variables (optional)

The deployment has sensible defaults. To override:

```bash
# Optional: create an .env file for custom configuration
cat > .env << 'EOF'
# API authentication key (default: dp-demo-key)
OMNISEC_API_KEY=dp-demo-key

# Telegram alerts (optional — leave blank to disable)
TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=
EOF
```

---

## Part 3: Deployment

### 3.1 Validate environment

Always run this first. It checks all required tools and configurations.

```bash
./scripts/validate-environment.sh
```

Expected output ends with:
```
ENVIRONMENT READY
```

Fix any `[FAIL]` items before proceeding.

### 3.2 Deploy

```bash
./scripts/deploy-design-partner.sh
```

This script:
1. Validates the environment
2. Optionally builds the Rust workspace locally to catch errors early
3. Builds all Docker images (10–20 minutes on first run, Rust compilation is slow)
4. Starts all six services
5. Waits for PostgreSQL and Redis to pass health checks
6. Waits for the API to respond
7. Prints a deployment summary with all URLs and the API key

### 3.3 Manual deploy (alternative)

If you prefer to run Docker Compose directly:

```bash
# From the repository root (important — not from infra/docker/)
REPO_ROOT="$(pwd)"

docker compose \
    --project-directory "$REPO_ROOT" \
    -f infra/docker/docker-compose.design-partner.yml \
    up -d --build
```

---

## Part 4: Health Verification

### 4.1 All containers running

```bash
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

Expected: six containers, all `Up` or `Up (healthy)`.

### 4.2 API health

```bash
curl http://localhost:3000/
# Expected: {"status":"healthy","service":"omnisec-api"}
```

### 4.3 Authenticated API calls

The design partner API key is `dp-demo-key`.

```bash
API_KEY="dp-demo-key"

# List discovered agents
curl -H "X-API-Key: $API_KEY" http://localhost:3000/api/agents

# List recent events
curl -H "X-API-Key: $API_KEY" http://localhost:3000/api/events

# Security risk scores
curl -H "X-API-Key: $API_KEY" http://localhost:3000/api/security/risk-scores

# Prometheus metrics
curl -H "X-API-Key: $API_KEY" http://localhost:3000/metrics
```

### 4.4 Infrastructure checks

```bash
# PostgreSQL
docker exec omnisec-dp-postgres pg_isready -U postgres

# Redis
docker exec omnisec-dp-redis redis-cli ping
# Expected: PONG

# NATS
curl http://localhost:8222/varz | python3 -m json.tool | head -20
```

### 4.5 Dashboard

Open a browser and navigate to:  
`http://<VM_IP>:3002`

The dashboard displays:
- Agent discovery (Security tab)
- Enforcement decisions (Enforcement tab)
- Reliability metrics (Reliability tab)
- Policy validation (Validation tab)

### 4.6 eBPF status

```bash
# Check whether daemon is using eBPF or /proc fallback
docker logs omnisec-dp-daemon 2>&1 | grep -E "eBPF|ebpf|fallback|kernel event"
```

Expected (eBPF available):
```
Kernel event stream: using eBPF (sub-second kernel telemetry)
```

Expected (fallback):
```
Kernel event stream: using /proc fallback (1s resolution)
```

---

## Part 5: Troubleshooting

### Containers not starting

```bash
# Check all container statuses
docker ps -a

# Check logs for a specific container
docker logs omnisec-dp-api --tail 50
docker logs omnisec-dp-daemon --tail 50
docker logs omnisec-dp-postgres --tail 20
```

### API returns 401 Unauthorized

All endpoints except `GET /` require the `X-API-Key` header:

```bash
curl -H "X-API-Key: dp-demo-key" http://localhost:3000/api/agents
```

### PostgreSQL migration errors

```bash
# Check if PostgreSQL is healthy
docker exec omnisec-dp-postgres pg_isready -U postgres

# Check what tables exist
docker exec -it omnisec-dp-postgres psql -U postgres -d omnisec -c "\dt"
```

Migrations run automatically on API/daemon startup. If they fail, check the API logs:

```bash
docker logs omnisec-dp-api 2>&1 | grep -i "migrat"
```

### Dashboard cannot reach API

The dashboard container reaches the API at `http://api:3000` (internal Docker network). If the API is not yet running, the dashboard will show errors. Ensure the API starts first:

```bash
docker logs omnisec-dp-dashboard --tail 30
```

### Port conflicts

If any port is already in use:

```bash
# Find what is using port 3000
sudo ss -tlnp | grep ':3000'

# Stop the conflicting process and redeploy
```

### eBPF permissions error

```bash
docker logs omnisec-dp-daemon 2>&1 | grep -i "error\|bpf\|permission"
```

If eBPF fails to load (expected in most Docker environments), the daemon falls back to `/proc` polling automatically. Safe mode means no actual enforcement is applied.

### Complete stack reset

```bash
REPO_ROOT="$(pwd)"

# Stop and remove all containers and volumes (DATA WILL BE LOST)
docker compose \
    --project-directory "$REPO_ROOT" \
    -f infra/docker/docker-compose.design-partner.yml \
    down -v

# Rebuild and restart
./scripts/deploy-design-partner.sh
```

---

## Architecture Notes

### Safe Mode

In design partner mode (`OMNISEC_SAFE_MODE=1`):
- The daemon detects anomalies and makes enforcement decisions
- **No kernel enforcement is applied** (no nftables rules, no SIGSTOP/SIGKILL)
- All decisions are logged and published to NATS for review
- The dashboard shows all decisions and risk scores

### Database Migrations

The sqlx migrations in `crates/storage/migrations/` are embedded at compile time. They run automatically when the API or daemon connects to PostgreSQL. Migration 001 creates the base schema including the `uuid-ossp` extension.

### eBPF vs /proc fallback

- eBPF requires kernel 5.8+, BTF support, and `CAP_BPF` inside the container
- Docker containers with only `SYS_PTRACE`, `NET_ADMIN`, `DAC_READ_SEARCH` will use the `/proc` fallback
- The `/proc:/host/proc:ro` volume mount enables the fallback mode
- Both modes produce the same NATS events and dashboard data

### NATS JetStream

The daemon uses NATS with JetStream for persistent event streams. NATS data is stored in the `omnisec_dp_nats` Docker volume. Subjects used:

- `omnisec.agents.discovered`
- `omnisec.agents.failed`
- `omnisec.security.anomaly_detected`
- `omnisec.security.correlation_alert`
- `omnisec.enforcement.decision_made`
- `omnisec.runtime.network_blocked`
- `omnisec.>`  (wildcard — audit trail)
