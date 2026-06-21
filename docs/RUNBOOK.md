# Omnisec Operator Runbook

**Version:** 0.2.0  
**Repository branch:** master  
**Deployment target:** Ubuntu 24.04 LTS VM

This runbook contains the exact commands to deploy and operate Omnisec. No placeholders — all commands use values derived from the repository.

---

## Section A: Commands to Run on Mac

These commands prepare the repository and transfer it to the Ubuntu VM.

### A.1 Stage all deployment automation files

```bash
cd ~/Desktop/omnisec

# Verify new files are present
git status

# Stage all new files
git add \
    scripts/validate-environment.sh \
    scripts/deploy-design-partner.sh \
    postgres/init.sql \
    docs/DEPLOYMENT_GUIDE.md \
    docs/RUNBOOK.md \
    DEPLOYMENT_AUTOMATION_REPORT.md
```

### A.2 Commit

```bash
git commit -m "Add deployment automation scripts, runbooks, and postgres init"
```

### A.3 Push to remote (requires GitHub/GitLab remote)

The repository currently has **no remote configured**. You must add one before pushing.

**Option A — Add a GitHub remote:**

```bash
# Create a new repo on github.com first, then:
git remote add origin git@github.com:<YOUR_GITHUB_USERNAME>/omnisec.git
git push -u origin master
```

**Option B — rsync directly to Ubuntu VM (no GitHub needed):**

```bash
# Replace <VM_IP> with your Ubuntu VM's IP address
VM_IP="<VM_IP>"
VM_USER="ubuntu"

rsync -avz --exclude='.git' \
    ~/Desktop/omnisec/ \
    "${VM_USER}@${VM_IP}:~/omnisec/"
```

> Use rsync if you don't want to set up GitHub. It copies all files directly.

### A.4 Verify what will be deployed (Mac sanity check)

```bash
# Confirm the compose file is correct
cat ~/Desktop/omnisec/infra/docker/docker-compose.design-partner.yml

# Confirm scripts exist and are not empty
wc -l ~/Desktop/omnisec/scripts/validate-environment.sh
wc -l ~/Desktop/omnisec/scripts/deploy-design-partner.sh

# Confirm postgres init.sql exists
cat ~/Desktop/omnisec/postgres/init.sql
```

---

## Section B: Commands to Run on Ubuntu

SSH into your Ubuntu 24.04 VM, then run these commands in order.

### B.1 Initial system setup (one-time)

```bash
# Update system packages
sudo apt-get update && sudo apt-get upgrade -y

# Install required packages
sudo apt-get install -y \
    curl wget git ca-certificates gnupg lsb-release \
    build-essential pkg-config libssl-dev \
    clang llvm \
    linux-tools-common linux-tools-$(uname -r) \
    nftables iproute2 net-tools \
    python3 jq

# Install Docker (official method)
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

echo "deb [arch=$(dpkg --print-architecture) \
    signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
    https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Add current user to docker group
sudo usermod -aG docker "$USER"

# Apply group membership without logging out
newgrp docker

# Start and enable Docker
sudo systemctl enable --now docker

# Verify Docker is running
docker --version
docker compose version
```

### B.2 Mount BPF filesystem (one-time, for eBPF support)

```bash
# Mount BPF filesystem
sudo mount -t bpf bpffs /sys/fs/bpf

# Make it persistent across reboots
grep -q bpffs /etc/fstab \
    || echo 'bpffs /sys/fs/bpf bpf defaults 0 0' | sudo tee -a /etc/fstab

# Verify
ls /sys/fs/bpf
```

### B.3 Get the repository onto Ubuntu

**If you pushed to GitHub (Option A from Section A):**

```bash
git clone git@github.com:<YOUR_GITHUB_USERNAME>/omnisec.git ~/omnisec
cd ~/omnisec
```

**If you used rsync (Option B from Section A):**

```bash
# Files are already at ~/omnisec/ from rsync
cd ~/omnisec

# Initialize as git repo if you want version tracking
git init
git add .
git commit -m "initial deploy"
```

### B.4 Make scripts executable

```bash
cd ~/omnisec
chmod +x scripts/validate-environment.sh
chmod +x scripts/deploy-design-partner.sh
```

### B.5 Run environment validation

```bash
cd ~/omnisec
./scripts/validate-environment.sh
```

All checks must show `[PASS]` or `[WARN]`. Fix any `[FAIL]` items before continuing.

Expected final line: `ENVIRONMENT READY`

### B.6 Deploy Omnisec

```bash
cd ~/omnisec
./scripts/deploy-design-partner.sh
```

**What this does:**
1. Re-validates environment
2. Optionally builds Rust workspace (if cargo is installed)
3. Builds all Docker images (~15 minutes on first run)
4. Starts PostgreSQL, Redis, NATS, daemon, API, dashboard
5. Waits for each service to become healthy
6. Prints deployment summary

**Expected final output:**
```
═══ Deployment Summary ═══
╔══════════════════════════════════════════════════════════════╗
║                 OMNISEC DEPLOYMENT COMPLETE                  ║
╚══════════════════════════════════════════════════════════════╝

  API           http://localhost:3000
  Dashboard     http://localhost:3002
  NATS          nats://localhost:4222
  NATS Monitor  http://localhost:8222
  PostgreSQL    localhost:5432
  Redis         localhost:6379

  API Key:      dp-demo-key
  Safe Mode:    ENABLED
```

### B.7 Skip Rust build (faster deploy if cargo is slow)

```bash
cd ~/omnisec
./scripts/deploy-design-partner.sh --skip-build
```

---

## Section C: Verification Commands

Run these after deployment to confirm everything is working.

### C.1 Docker container status

```bash
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

Expected output (all containers Up):
```
NAMES                    STATUS                    PORTS
omnisec-dp-dashboard     Up N seconds              0.0.0.0:3002->3000/tcp
omnisec-dp-api           Up N seconds (healthy)    0.0.0.0:3000->3000/tcp
omnisec-dp-daemon        Up N seconds              
omnisec-dp-nats          Up N seconds              0.0.0.0:4222->4222/tcp, 0.0.0.0:8222->8222/tcp
omnisec-dp-redis         Up N seconds (healthy)    0.0.0.0:6379->6379/tcp
omnisec-dp-postgres      Up N seconds (healthy)    0.0.0.0:5432->5432/tcp
```

### C.2 API health check (unauthenticated)

```bash
curl -s http://localhost:3000/ | python3 -m json.tool
```

Expected:
```json
{
    "status": "healthy",
    "service": "omnisec-api"
}
```

### C.3 Authenticated API calls

```bash
API_KEY="dp-demo-key"

# List agents discovered by daemon
curl -s -H "X-API-Key: $API_KEY" http://localhost:3000/api/agents | python3 -m json.tool

# List recent events
curl -s -H "X-API-Key: $API_KEY" http://localhost:3000/api/events | python3 -m json.tool

# Security risk scores
curl -s -H "X-API-Key: $API_KEY" http://localhost:3000/api/security/risk-scores | python3 -m json.tool

# Enforcement decisions
curl -s -H "X-API-Key: $API_KEY" http://localhost:3000/api/enforcement/decisions | python3 -m json.tool

# Enforcement stats
curl -s -H "X-API-Key: $API_KEY" http://localhost:3000/api/enforcement/stats | python3 -m json.tool
```

### C.4 Prometheus metrics

```bash
# API-level metrics
curl -s -H "X-API-Key: dp-demo-key" http://localhost:3000/metrics

# Daemon-level metrics (accessed via docker exec since port 3003 is not host-exposed)
docker exec omnisec-dp-daemon \
    wget -qO- http://localhost:3003/metrics
```

### C.5 Database checks

```bash
# PostgreSQL ready check
docker exec omnisec-dp-postgres pg_isready -U postgres
# Expected: /var/run/postgresql:5432 - accepting connections

# Count tables (should be 10+ after migrations run)
docker exec -it omnisec-dp-postgres \
    psql -U postgres -d omnisec -c "\dt" | grep -c "table"

# Check organization was bootstrapped
docker exec -it omnisec-dp-postgres \
    psql -U postgres -d omnisec -c "SELECT id, name, slug FROM organizations;"

# Check agents table (will be empty until daemon runs a discovery cycle)
docker exec -it omnisec-dp-postgres \
    psql -U postgres -d omnisec -c "SELECT COUNT(*) FROM agents;"
```

### C.6 NATS checks

```bash
# NATS server info
curl -s http://localhost:8222/varz | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f'Server: {d[\"server_name\"]}')
print(f'Version: {d[\"version\"]}')
print(f'Connections: {d[\"connections\"]}')
print(f'Total messages: {d[\"total_messages\"]}')
"

# NATS JetStream info
curl -s http://localhost:8222/jsz | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f'Streams: {d.get(\"streams\", 0)}')
print(f'Consumers: {d.get(\"consumers\", 0)}')
" 2>/dev/null || echo "JetStream: no streams yet (normal on fresh start)"

# NATS subscriptions (shows omnisec.> subjects)
curl -s http://localhost:8222/subsz | python3 -m json.tool | head -40
```

### C.7 eBPF checks

```bash
# Check whether daemon is using eBPF or /proc fallback
docker logs omnisec-dp-daemon 2>&1 | grep -E "eBPF|ebpf|fallback|kernel event stream"

# Check kernel BTF (required for eBPF)
ls -la /sys/kernel/btf/vmlinux 2>/dev/null \
    && echo "BTF available — eBPF CO-RE supported" \
    || echo "BTF not available — daemon uses /proc fallback"

# Check eBPF filesystem
ls /sys/fs/bpf && echo "BPF filesystem mounted" || echo "BPF filesystem NOT mounted"

# List loaded eBPF programs on the host (if bpftool is available)
sudo bpftool prog list 2>/dev/null || echo "bpftool not available"
```

### C.8 nftables checks

```bash
# List nftables rulesets in daemon container
# (daemon uses NET_ADMIN capability; in safe mode, rules are not actually applied)
docker exec omnisec-dp-daemon \
    sh -c 'which nft && nft list ruleset 2>/dev/null || echo "nft not installed in container (expected)"'

# List host nftables rules (shows daemon rules if not in safe mode)
sudo nft list ruleset 2>/dev/null || echo "No nft rules on host"
```

### C.9 Daemon health (internal)

```bash
# Daemon health endpoint — not exposed to host, accessed via docker exec
docker exec omnisec-dp-daemon \
    wget -qO- http://localhost:3003/health 2>/dev/null \
    || echo "wget not available in daemon container; check logs instead"

# Check daemon is running
docker inspect omnisec-dp-daemon --format='{{.State.Status}} (restart count: {{.RestartCount}})'

# Recent daemon activity
docker logs omnisec-dp-daemon --tail 50 2>&1 | grep -v "^$"
```

---

## Section D: Failure Recovery

### D.1 Restart a single service

```bash
REPO_ROOT="$HOME/omnisec"

# Restart daemon only
docker compose \
    --project-directory "$REPO_ROOT" \
    -f "$REPO_ROOT/infra/docker/docker-compose.design-partner.yml" \
    restart daemon

# Restart API only
docker compose \
    --project-directory "$REPO_ROOT" \
    -f "$REPO_ROOT/infra/docker/docker-compose.design-partner.yml" \
    restart api

# Restart dashboard only
docker compose \
    --project-directory "$REPO_ROOT" \
    -f "$REPO_ROOT/infra/docker/docker-compose.design-partner.yml" \
    restart dashboard
```

### D.2 Restart the full stack (preserves data)

```bash
REPO_ROOT="$HOME/omnisec"

docker compose \
    --project-directory "$REPO_ROOT" \
    -f "$REPO_ROOT/infra/docker/docker-compose.design-partner.yml" \
    restart
```

### D.3 Stop the full stack

```bash
REPO_ROOT="$HOME/omnisec"

docker compose \
    --project-directory "$REPO_ROOT" \
    -f "$REPO_ROOT/infra/docker/docker-compose.design-partner.yml" \
    down
```

### D.4 Full reset (destroys all data)

```bash
REPO_ROOT="$HOME/omnisec"

# WARNING: This deletes all PostgreSQL and NATS data
docker compose \
    --project-directory "$REPO_ROOT" \
    -f "$REPO_ROOT/infra/docker/docker-compose.design-partner.yml" \
    down -v

# Redeploy from scratch
cd "$REPO_ROOT"
./scripts/deploy-design-partner.sh
```

### D.5 View logs

```bash
# All services — follow live
REPO_ROOT="$HOME/omnisec"
docker compose \
    --project-directory "$REPO_ROOT" \
    -f "$REPO_ROOT/infra/docker/docker-compose.design-partner.yml" \
    logs -f

# Daemon only (most verbose — eBPF, anomaly, enforcement events)
docker logs omnisec-dp-daemon -f --tail 100

# API only
docker logs omnisec-dp-api -f --tail 50

# PostgreSQL startup and migration logs
docker logs omnisec-dp-postgres --tail 30

# Dashboard build/startup
docker logs omnisec-dp-dashboard --tail 20

# NATS
docker logs omnisec-dp-nats --tail 20
```

### D.6 Inspect a container

```bash
# Detailed state including health status and restart count
docker inspect omnisec-dp-daemon | python3 -c "
import sys, json
c = json.load(sys.stdin)[0]
s = c['State']
print(f'Status: {s[\"Status\"]}')
print(f'Running: {s[\"Running\"]}')
print(f'StartedAt: {s[\"StartedAt\"]}')
print(f'RestartCount: {c[\"RestartCount\"]}')
"

# Environment variables in a running container
docker exec omnisec-dp-api env | grep OMNISEC

# Network connections from daemon container
docker exec omnisec-dp-daemon cat /proc/net/tcp 2>/dev/null | head -20
```

### D.7 Daemon crashed / not starting

```bash
# Check why daemon exited
docker logs omnisec-dp-daemon 2>&1 | tail -30

# Common causes:
# 1. Cannot connect to NATS — wait for nats container to start
# 2. Cannot connect to PostgreSQL — wait for postgres to be healthy
# 3. Permission error reading /proc — check cap_add in compose

# Force restart daemon
docker restart omnisec-dp-daemon

# Check status after restart
sleep 5
docker logs omnisec-dp-daemon --tail 20
```

### D.8 PostgreSQL not accepting connections

```bash
# Check PostgreSQL health
docker exec omnisec-dp-postgres pg_isready -U postgres

# Check PostgreSQL logs
docker logs omnisec-dp-postgres --tail 30

# Connect to PostgreSQL interactively
docker exec -it omnisec-dp-postgres psql -U postgres -d omnisec

# Check data directory permissions
docker exec omnisec-dp-postgres ls -la /var/lib/postgresql/data/ | head -5
```

### D.9 API returns 500 errors (migration failure)

```bash
# Check API logs for migration errors
docker logs omnisec-dp-api 2>&1 | grep -i "migrat\|error\|failed" | tail -20

# Verify PostgreSQL has the schema
docker exec -it omnisec-dp-postgres \
    psql -U postgres -d omnisec -c "\dt"

# If migrations failed, restart API (it will retry migrations on startup)
docker restart omnisec-dp-api
sleep 10
docker logs omnisec-dp-api --tail 20
```

### D.10 Rebuild a specific image

```bash
REPO_ROOT="$HOME/omnisec"

# Rebuild daemon image (e.g., after code changes)
docker compose \
    --project-directory "$REPO_ROOT" \
    -f "$REPO_ROOT/infra/docker/docker-compose.design-partner.yml" \
    build daemon

# Restart with new image
docker compose \
    --project-directory "$REPO_ROOT" \
    -f "$REPO_ROOT/infra/docker/docker-compose.design-partner.yml" \
    up -d daemon
```

### D.11 Out of disk space

```bash
# Check disk usage
df -h /

# Check Docker disk usage
docker system df

# Remove unused images and build cache (does NOT remove running containers or volumes)
docker system prune -f

# Remove dangling build caches
docker builder prune -f
```

---

## Quick Reference

| Action | Command |
|---|---|
| Deploy | `cd ~/omnisec && ./scripts/deploy-design-partner.sh` |
| Validate env | `./scripts/validate-environment.sh` |
| Stop all | `docker compose --project-directory ~/omnisec -f ~/omnisec/infra/docker/docker-compose.design-partner.yml down` |
| Restart all | `docker compose --project-directory ~/omnisec -f ~/omnisec/infra/docker/docker-compose.design-partner.yml restart` |
| View logs | `docker logs omnisec-dp-daemon -f` |
| API health | `curl http://localhost:3000/` |
| API agents | `curl -H "X-API-Key: dp-demo-key" http://localhost:3000/api/agents` |
| Dashboard | `http://localhost:3002` |
| NATS monitor | `http://localhost:8222` |
| DB connect | `docker exec -it omnisec-dp-postgres psql -U postgres -d omnisec` |
| Redis CLI | `docker exec -it omnisec-dp-redis redis-cli` |
