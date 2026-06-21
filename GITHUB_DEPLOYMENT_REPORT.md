# GITHUB DEPLOYMENT REPORT
**Date:** 2026-06-21  
**Commit:** `eb5d1d0`  
**Branch:** `main`  
**Push:** `cbf118f → eb5d1d0` pushed to `origin/main`

---

## Commit Summary

```
fix: eliminate 5 production beta blockers
```

All 5 blockers identified in BETA_VALIDATION_REPORT.md addressed in a single commit.

---

## Files Changed (10 files)

| File | Change | Blocker |
|---|---|---|
| `crates/storage/src/lib.rs` | `$4` → `$4::event_type` in INSERT, added error logging | B1 |
| `crates/events/src/lib.rs` | Added `CONFIG_MODE_CHANGE` NATS subject | B4 |
| `infra/docker/docker-compose.design-partner.yml` | Added SYS_ADMIN, KILL, BPF, PERFMON caps; cgroup + BTF volumes; cgroupns:host | B2 + B3 |
| `services/daemon/src/main.rs` | DesignPartnerConfig → AtomicBool; mode-change NATS listener | B4 |
| `apps/api/Cargo.toml` | Added omnisec-messaging + omnisec-events dependencies | B4 |
| `apps/api/src/main.rs` | NatsClient in AppState; POST /api/config/mode endpoint | B4 |
| `docs/DEPLOYMENT_GUIDE.md` | Ubuntu 24.04 → 26.04, OS table, mode toggle docs, cap table | B5 |
| `README.md` | Full rewrite with accurate requirements | B5 |
| `BETA_VALIDATION_REPORT.md` | Full beta validation findings | — |
| `LOCAL_FIX_VALIDATION.md` | Local verification report | — |

---

## Migrations Added

**None.** No new SQL migrations were required. All fixes are application-level:
- B1 uses a PostgreSQL inline cast (`::event_type`) — no schema change
- B4 uses the existing `state_config` table (migration 006) for mode persistence

---

## Tests Added

| Test | Status |
|---|---|
| `cargo test` — full workspace | **0 failures** |
| `cargo build` — full workspace | **0 errors** |
| `cargo clippy` — full workspace | **0 errors** |
| `cargo fmt` — full workspace | Clean |

No new unit tests were added for the B1 fix (requires live PostgreSQL). Integration test coverage for event persistence is tracked as a remaining priority item in the original BETA_VALIDATION_REPORT.md.

---

## Deployment Impact

### B1 (event_type ENUM cast)
- **Impact on existing data:** None — previously-failing INSERTs produced no rows. The fix means rows are now created correctly.
- **Rollback risk:** None — the cast `$4::event_type` is backward-compatible with all existing `event_type` enum values

### B2 + B3 (Docker capabilities)
- **Impact:** Daemon container now has additional Linux capabilities. This increases the daemon's privilege surface.
- **Enforcement change:** In safe mode (`OMNISEC_SAFE_MODE=1`), enforcement is still logged-not-applied. The capability additions allow enforcement to execute when safe mode is disabled.
- **Rollback:** Remove the new `cap_add` entries and volume mounts from docker-compose

### B4 (safe mode toggle)
- **Impact on existing deployment:** The API now attempts a NATS connection at startup. If NATS is unavailable, the API starts normally with a warning.
- **Breaking change:** None — all existing endpoints unchanged. New endpoint: `POST /api/config/mode`
- **Default behavior:** `OMNISEC_SAFE_MODE=1` env var still controls initial mode. Runtime toggle overrides it without restart.

### B5 (docs)
- **Impact:** Documentation only. No code behavior changed.

---

## Ubuntu Deployment Instructions

SSH to Ubuntu VM and run:

```bash
# 1. Pull the latest code
cd ~/omnisec
git pull origin main

# 2. Rebuild all images with new capabilities (rebuild required for compose changes)
docker compose -f infra/docker/docker-compose.design-partner.yml down

docker compose -f infra/docker/docker-compose.design-partner.yml build --no-cache

# 3. Redeploy
docker compose -f infra/docker/docker-compose.design-partner.yml up -d

# OR: use the deploy script
bash scripts/deploy-design-partner.sh --skip-build
```

After deployment, verify:

```bash
# B1 — event telemetry working
curl -s -H "X-API-Key: dp-demo-key" http://localhost:3000/api/events | python3 -m json.tool | head -20

# B2 — capabilities granted
docker inspect omnisec-dp-daemon --format '{{.HostConfig.CapAdd}}'
# Expected: [SYS_PTRACE NET_ADMIN DAC_READ_SEARCH SYS_ADMIN KILL BPF PERFMON]

# B3 — eBPF status
docker logs omnisec-dp-daemon 2>&1 | grep -i "ebpf\|fallback"

# B4 — mode toggle
curl -X POST -H "X-API-Key: dp-demo-key" \
  -H "Content-Type: application/json" \
  -d '{"mode":"enforcement"}' \
  http://localhost:3000/api/config/mode
# Expected: {"status":"ok","mode":"enforcement","nats":"published"}

# Verify daemon got the mode change
sleep 2 && docker logs omnisec-dp-daemon --tail 5 2>&1 | grep -i "mode changed"
```
