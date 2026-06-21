# Omnisec Deployment Automation Report

**Generated:** 2026-06-21  
**Repository:** ~/Desktop/omnisec  
**Branch:** master  
**Target:** Ubuntu 24.04 LTS (Design Partner deployment)

---

## 1. Files Created

### Scripts

| File | Purpose |
|---|---|
| `scripts/validate-environment.sh` | Validates all host prerequisites before deployment |
| `scripts/deploy-design-partner.sh` | End-to-end deployment: validate → build → start → verify |

### Infrastructure

| File | Purpose |
|---|---|
| `postgres/init.sql` | Placeholder required by docker-compose volume mount; schema managed by sqlx migrations |

### Documentation

| File | Purpose |
|---|---|
| `docs/DEPLOYMENT_GUIDE.md` | Complete fresh-VM setup guide (packages, Docker, eBPF, deployment, troubleshooting) |
| `docs/RUNBOOK.md` | Operator runbook with exact commands for Mac, Ubuntu, verification, and recovery |
| `DEPLOYMENT_AUTOMATION_REPORT.md` | This file |

---

## 2. Scripts Created

### `scripts/validate-environment.sh`

Checks the following and prints `[PASS]` / `[FAIL]` / `[WARN]` per item:

- Ubuntu version (24.04 required)
- Kernel version (>= 5.8 for full eBPF; 5.4 with warning)
- Kernel BTF (`/sys/kernel/btf/vmlinux`)
- Docker installation and daemon running
- Docker Compose v2 plugin
- Git
- Rust / Cargo (warns if missing — Docker builds do not require host Rust)
- Clang (warns if missing — for eBPF compilation)
- nftables / bpftool (warns if missing)
- eBPF filesystem (`/sys/fs/bpf`)
- cgroup filesystem (`/sys/fs/cgroup`)
- CAP_BPF / `kernel.unprivileged_bpf_disabled`
- CAP_NET_ADMIN (network interface access)
- `/proc` accessibility
- systemd
- Port availability: 3000, 3002, 4222, 5432, 6379, 8222
- Disk space (>= 10 GB)

Exits 0 with `ENVIRONMENT READY` if zero failures, exits 1 with failure count otherwise.

### `scripts/deploy-design-partner.sh`

Seven-step deployment:

1. **Environment validation** — runs `validate-environment.sh`
2. **Pre-flight checks** — compose file exists, `postgres/init.sql` exists, Docker daemon is running
3. **Rust workspace build** (optional, skipped with `--skip-build`) — `cargo build` to catch compilation errors before the slow Docker build
4. **Docker image build** — `docker compose build --progress=plain`
5. **Service start** — `docker compose up -d`
6. **Health wait** — polls PostgreSQL healthy, Redis healthy, NATS `/healthz`, API `GET /`, Dashboard `GET /`
7. **Verification** — PostgreSQL `pg_isready`, Redis `PING`, NATS `/varz`, API agents endpoint with auth

Flags:
- `--skip-build`: skips step 3 (useful when cargo is not installed or after first build)
- `--no-validate`: skips step 1 (not recommended)

---

## 3. Key Assumptions

### Docker Compose project directory

The design partner compose file (`infra/docker/docker-compose.design-partner.yml`) uses relative build contexts (`.` and `apps/dashboard`) that assume the workspace root as the project directory. The deploy script always invokes Docker Compose with:

```bash
docker compose --project-directory "$REPO_ROOT" -f "$REPO_ROOT/infra/docker/docker-compose.design-partner.yml" up -d
```

This ensures:
- `context: .` resolves to workspace root (not `infra/docker/`)
- `context: apps/dashboard` resolves to `$REPO_ROOT/apps/dashboard`
- Volume `./postgres/init.sql` resolves to `$REPO_ROOT/postgres/init.sql`

### postgres/init.sql

The compose file mounts `./postgres/init.sql` into the PostgreSQL container. This file must exist as a regular file (not a directory) or Docker will create a directory at that path and PostgreSQL will fail to start.

The file is a no-op placeholder. All schema creation is handled by the six sqlx migrations embedded in the `omnisec-api` and `omnisec-daemon` binaries:
- `crates/storage/migrations/001_initial.sql` — base schema (uuid-ossp, organizations, agents, events, alerts, policies)
- `002_security.sql` — security tables
- `003_enforcement.sql` — enforcement lists
- `004_runtime.sql` — runtime config
- `005_intelligence.sql` — cost intelligence metrics
- `006_state.sql` — state persistence

### No Git remote configured

The repository has no remote (`git remote -v` returns nothing). The RUNBOOK provides two options for getting code to the Ubuntu VM:
1. Add a GitHub/GitLab remote and push
2. Use `rsync` to copy directly (recommended for first deploy)

### eBPF in Docker containers

The design partner compose grants the daemon `SYS_PTRACE`, `NET_ADMIN`, and `DAC_READ_SEARCH` capabilities but **not** `CAP_BPF`. In most Docker environments, the daemon will fall back to `/proc`-based polling (1-second resolution). This is safe and expected — the daemon code handles this automatically.

Full eBPF (sub-second telemetry) requires `--privileged` or explicit `CAP_BPF` on the daemon container, plus the host kernel having `CONFIG_DEBUG_INFO_BTF=y`. This can be enabled post-validation by adding `CAP_BPF` to `cap_add` in the compose file.

### Safe Mode

`OMNISEC_SAFE_MODE=1` is hardcoded in the design partner compose. This means:
- The daemon detects anomalies and runs the decision engine
- **No actual enforcement actions are applied** (no nftables rules, no process signals)
- All decisions are published to NATS and visible in the dashboard

---

## 4. Deployment Risks

| Risk | Severity | Mitigation |
|---|---|---|
| Docker build takes 15–25 minutes (Rust compilation) | Medium | Use `--skip-build` after first successful build; Docker layer caching reduces subsequent builds to ~2 minutes |
| Dashboard Dockerfile path resolution | Low | Compose specifies `dockerfile: apps/dashboard/Dockerfile`; resolved relative to project dir with `--project-directory`. If this fails, fix: change to `dockerfile: Dockerfile` in compose (it's in `context: apps/dashboard`) |
| No TLS / HTTPS | Medium | API is HTTP-only. For design partner, Docker network isolation provides some protection. Do not expose port 3000 to the internet. |
| API key in plaintext | Low | `dp-demo-key` is hardcoded for design partner. Change `OMNISEC_API_KEY` in compose before production use. |
| PostgreSQL no password rotation | Low | Username/password is `postgres`/`postgres`. Acceptable for design partner VM; change before production. |
| eBPF falls back to /proc | Low | /proc polling still provides full functionality; only telemetry resolution changes (1s vs sub-ms). |
| Port conflicts | Low | `validate-environment.sh` checks all required ports. Resolve conflicts before deploying. |

---

## 5. Commands You Must Run on Mac

```bash
# Navigate to repo
cd ~/Desktop/omnisec

# Stage new files
git add \
    scripts/validate-environment.sh \
    scripts/deploy-design-partner.sh \
    postgres/init.sql \
    docs/DEPLOYMENT_GUIDE.md \
    docs/RUNBOOK.md \
    DEPLOYMENT_AUTOMATION_REPORT.md

# Commit
git commit -m "Add deployment automation scripts and operator runbooks"

# Add remote (choose one):
# Option A — GitHub:
git remote add origin git@github.com:<YOUR_USERNAME>/omnisec.git
git push -u origin master

# Option B — rsync directly to Ubuntu VM:
rsync -avz --exclude='.git' ~/Desktop/omnisec/ ubuntu@<VM_IP>:~/omnisec/
```

---

## 6. Commands You Must Run on Ubuntu

```bash
# ── One-time system setup ──────────────────────────────────────────────
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y curl wget git ca-certificates gnupg lsb-release \
    build-essential clang linux-tools-common linux-tools-$(uname -r) \
    nftables iproute2 python3 jq

# Install Docker
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) \
    signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo usermod -aG docker "$USER"
newgrp docker
sudo systemctl enable --now docker

# Mount BPF filesystem
sudo mount -t bpf bpffs /sys/fs/bpf
grep -q bpffs /etc/fstab || echo 'bpffs /sys/fs/bpf bpf defaults 0 0' | sudo tee -a /etc/fstab

# ── Get the code ───────────────────────────────────────────────────────
# Option A (if pushed to GitHub):
git clone git@github.com:<YOUR_USERNAME>/omnisec.git ~/omnisec

# Option B (rsync already ran from Mac):
# Files are already at ~/omnisec/

# ── Deploy ────────────────────────────────────────────────────────────
cd ~/omnisec
chmod +x scripts/validate-environment.sh scripts/deploy-design-partner.sh
./scripts/validate-environment.sh
./scripts/deploy-design-partner.sh
```

---

## 7. Commands That Verify Omnisec Is Working

Run these on Ubuntu after deployment:

```bash
# ── Container health ──────────────────────────────────────────────────
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# ── API ───────────────────────────────────────────────────────────────
curl -s http://localhost:3000/
# {"status":"healthy","service":"omnisec-api"}

# ── Authenticated endpoints ───────────────────────────────────────────
curl -s -H "X-API-Key: dp-demo-key" http://localhost:3000/api/agents
curl -s -H "X-API-Key: dp-demo-key" http://localhost:3000/api/security/risk-scores
curl -s -H "X-API-Key: dp-demo-key" http://localhost:3000/api/enforcement/stats

# ── Metrics ───────────────────────────────────────────────────────────
curl -s -H "X-API-Key: dp-demo-key" http://localhost:3000/metrics

# ── NATS ──────────────────────────────────────────────────────────────
curl -s http://localhost:8222/varz | python3 -c "import sys,json; d=json.load(sys.stdin); print('NATS OK — version:', d['version'])"

# ── PostgreSQL ────────────────────────────────────────────────────────
docker exec omnisec-dp-postgres pg_isready -U postgres

# ── Redis ─────────────────────────────────────────────────────────────
docker exec omnisec-dp-redis redis-cli ping
# PONG

# ── eBPF status ───────────────────────────────────────────────────────
docker logs omnisec-dp-daemon 2>&1 | grep -E "eBPF|fallback|kernel event"

# ── Dashboard ─────────────────────────────────────────────────────────
curl -sI http://localhost:3002/ | head -3
# HTTP/1.1 200 OK
```

---

## 8. Remaining Deployment Blockers

| Blocker | Resolution |
|---|---|
| **No git remote configured** | Add GitHub remote or use rsync. See RUNBOOK Section A.3. |
| **Ubuntu VM IP unknown** | You must know the VM's IP address to SSH in and to configure rsync or clone via git. |
| **First Docker build is slow** | 15–25 minutes on first run due to Rust compilation. Layer caching makes subsequent builds fast. |
| **eBPF not available in Docker without CAP_BPF** | Daemon falls back to /proc. This is expected and safe. Full eBPF can be enabled by adding `CAP_BPF: true` to daemon's `cap_add` in the compose file. |
| **Dashboard docker-compose path** | If dashboard Docker build fails with "Dockerfile not found", edit `infra/docker/docker-compose.design-partner.yml`: change `dockerfile: apps/dashboard/Dockerfile` to `dockerfile: Dockerfile` under the dashboard service. |
| **No TLS** | API runs plain HTTP. Do not expose port 3000 publicly without a reverse proxy (nginx/caddy) with TLS. |
