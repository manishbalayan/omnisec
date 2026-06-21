# Omnisec

Runtime Control Plane for Autonomous AI Agents.

## Overview

Omnisec sits below AI agents and their harnesses at the operating system and network layers, providing reliability, security, and intelligence for autonomous AI systems.

## Architecture

- **Daemon**: Core orchestration — agent discovery, health monitoring, security pipeline, enforcement
- **API**: REST API (port 3000) — management, config, Prometheus metrics
- **Dashboard**: Next.js web UI (port 3002)
- **eBPF sensor**: Kernel-level process/network/file monitoring (falls back to `/proc` in Docker)
- **Policy Engine**: Priority-sorted rule evaluation with human overrides
- **Proxy**: Transparent proxy for AI model requests

## Requirements

| Requirement | Version |
|---|---|
| **OS** | Ubuntu 26.04 LTS (GLIBC 2.41 required) |
| **Docker** | 24.x+ with Compose v2 |
| **Rust** (dev only) | 1.91+ |
| **Kernel** | 7.x (eBPF optional, falls back to /proc on older kernels) |

> **Ubuntu 24.04 is NOT supported.** The Rust build chain uses `rust:1.91-slim` (Debian Trixie, GLIBC 2.41). Running on Ubuntu 24.04 (GLIBC 2.36) causes a startup crash.

## Quick Start (Design Partner)

```bash
git clone <repo> omnisec && cd omnisec
chmod +x scripts/deploy-design-partner.sh
./scripts/deploy-design-partner.sh
```

All six services start in safe mode — enforcement decisions are logged but no kernel actions are applied.

### Access

| Service | URL | Auth |
|---|---|---|
| API | `http://localhost:3000` | `X-API-Key: dp-demo-key` |
| Dashboard | `http://localhost:3002` | none |
| NATS | `nats://localhost:4222` | none |

### Toggle enforcement mode (no restart needed)

```bash
# Enable enforcement (nftables blocking, cgroup throttle, SIGSTOP active)
curl -X POST -H "X-API-Key: dp-demo-key" \
  -H "Content-Type: application/json" \
  -d '{"mode":"enforcement"}' \
  http://localhost:3000/api/config/mode

# Back to safe mode
curl -X POST -H "X-API-Key: dp-demo-key" \
  -H "Content-Type: application/json" \
  -d '{"mode":"safe"}' \
  http://localhost:3000/api/config/mode
```

## Development

```bash
# Build all crates
cargo build

# Run tests
cargo test

# Run API
cargo run --bin omnisec-api

# Run daemon
cargo run --bin omnisec-daemon

# Run dashboard
cd apps/dashboard && npm install && npm run dev
```

## Configuration

| Variable | Default | Description |
|---|---|---|
| `DATABASE_URL` | `postgres://postgres:postgres@localhost:5432/omnisec` | PostgreSQL connection |
| `REDIS_URL` | `redis://localhost:6379` | Redis connection |
| `NATS_URL` | `nats://localhost:4222` | NATS connection |
| `OMNISEC_SAFE_MODE` | `1` | `1` = enforcement logged not applied; `0` = live enforcement |
| `OMNISEC_API_KEY` | unset (auth disabled) | API key for `X-API-Key` header |
| `TELEGRAM_BOT_TOKEN` | unset | Telegram alerts (optional) |
| `TELEGRAM_CHAT_ID` | unset | Telegram chat ID (optional) |

## eBPF Status

In Docker, the daemon runs in `/proc fallback` mode (1-second resolution). Native eBPF requires:
- Kernel 5.8+ with BTF (`/sys/kernel/btf/vmlinux`)
- `CAP_BPF` + `CAP_PERFMON` granted to the container
- `bpf-linker` installed in the build environment

Both modes produce identical NATS events and dashboard data.

## License

MIT
