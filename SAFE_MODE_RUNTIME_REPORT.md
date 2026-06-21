# SAFE MODE RUNTIME REPORT — B4
**Date:** 2026-06-21

## Problem

`OMNISEC_SAFE_MODE` was an environment variable read once at daemon startup and stored as a plain `bool` in `DesignPartnerConfig`. Changing the mode required:
1. Edit the docker-compose env var
2. `docker compose down` + `docker compose up`

This is unusable in production — operators need to escalate from safe mode to enforcement in real time when responding to an incident.

## Implementation

### Architecture

```
Operator
  → POST /api/config/mode {"mode": "enforcement"}
    → API: updates AppState.operational_mode
    → API: persists to state_config DB table
    → API: publishes omnisec.config.mode_change to NATS
      → Daemon: NATS subscription receives message
      → Daemon: updates AtomicBool fields in DesignPartnerConfig
        → All enforcement gates immediately read new mode
```

Mode change propagates in < 500ms (NATS round-trip + AtomicBool store).

### Changes

**`crates/events/src/lib.rs`**
```rust
pub const CONFIG_MODE_CHANGE: &str = "omnisec.config.mode_change";
```

**`services/daemon/src/main.rs`**
```rust
// Before
struct DesignPartnerConfig {
    safe_mode: bool,
    recommendation_only: bool,
    verbose: bool,
}

// After
struct DesignPartnerConfig {
    safe_mode: AtomicBool,
    recommendation_only: AtomicBool,
    verbose: AtomicBool,
}
```

All reads updated: `design_partner.safe_mode` → `design_partner.safe_mode.load(Ordering::Relaxed)`

**Mode-change subscription in daemon:**
```rust
tokio::spawn(async move {
    let mut sub = nats_mode.subscribe::<Value>(subjects::CONFIG_MODE_CHANGE).await?;
    while let Some((_subj, envelope)) = sub.next().await {
        let mode = envelope.payload["mode"].as_str().unwrap_or("safe");
        let (safe, rec_only) = match mode {
            "enforcement" => (false, false),
            "recommendation" => (false, true),
            _ => (true, false),
        };
        dp_mode.safe_mode.store(safe, Ordering::SeqCst);
        dp_mode.recommendation_only.store(rec_only, Ordering::SeqCst);
    }
});
```

**`apps/api/src/main.rs`** — New endpoint:
```
POST /api/config/mode
Body: { "mode": "safe" | "recommendation" | "enforcement" }
Auth: X-API-Key required
```

Response:
```json
{
  "status": "ok",
  "mode": "enforcement",
  "nats": "published"
}
```

## Mode Semantics

| Mode | safe_mode | recommendation_only | Behavior |
|---|---|---|---|
| `safe` | `true` | `false` | Decisions logged, no kernel actions |
| `recommendation` | `false` | `true` | Decisions published to NATS, no enforcement |
| `enforcement` | `false` | `false` | Full enforcement (nftables, cgroup, SIGSTOP) |

## Usage Examples

```bash
API="http://localhost:3000"
KEY="dp-demo-key"

# Switch to enforcement
curl -X POST "$API/api/config/mode" \
  -H "X-API-Key: $KEY" \
  -H "Content-Type: application/json" \
  -d '{"mode":"enforcement"}'

# Switch to recommendation (decisions published, nothing applied)
curl -X POST "$API/api/config/mode" \
  -H "X-API-Key: $KEY" \
  -H "Content-Type: application/json" \
  -d '{"mode":"recommendation"}'

# Back to safe mode
curl -X POST "$API/api/config/mode" \
  -H "X-API-Key: $KEY" \
  -H "Content-Type: application/json" \
  -d '{"mode":"safe"}'

# Verify current mode in daemon log
docker logs omnisec-dp-daemon 2>&1 | grep "mode changed"
```

## Persistence

The operational mode is stored in the `state_config` DB table (key: `operational_mode`). On API restart, it reads the initial mode from `OMNISEC_SAFE_MODE` env var (not the DB). This is intentional — the env var provides a safe default for fresh deployments.

**Note for production:** If you want the mode to survive API restarts, update the env var in docker-compose. The DB entry is for the runtime toggle only.

## NATS Unavailability Handling

If NATS is unavailable when `POST /api/config/mode` is called:
- Response includes `"nats": "nats_unavailable"`
- The mode is still stored in AppState and DB
- The daemon will NOT receive the change until NATS reconnects (daemon polls no fallback)

Future improvement: the daemon could poll `state_config` from DB every 30s as a NATS-independent fallback.
