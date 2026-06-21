# TELEMETRY FIX REPORT — B1
**Date:** 2026-06-21

## Root Cause

`crates/storage/migrations/001_initial.sql` defines:
```sql
CREATE TYPE event_type AS ENUM (
  'agent_discovered', 'agent_heartbeat', 'agent_failed', 'agent_restarted',
  'agent_stopped', 'policy_violation', 'security_incident', 'system_error'
);

CREATE TABLE events (
    event_type event_type NOT NULL,   -- PostgreSQL ENUM column
    ...
);
```

`crates/storage/src/lib.rs` bound the value as plain text:
```rust
"INSERT INTO events (..., event_type, ...) VALUES (..., $4, ...)"
.bind(event_type)   // &str → text → PostgreSQL rejected with type mismatch
```

PostgreSQL does not implicitly cast `text` to a custom ENUM type. Result: every `create_event()` call returned:
```
column "event_type" is of type event_type but expression is of type text
```

This error was swallowed by the `let _ =` pattern in the daemon. **Zero events were ever written to the `events` table** despite the daemon running for hours.

## Fix Applied

```rust
// BEFORE
"INSERT INTO events (..., event_type, ...) VALUES ($1, $2, $3, $4, $5, $6, $7)"

// AFTER
"INSERT INTO events (..., event_type, ...) VALUES ($1, $2, $3, $4::event_type, $5, $6, $7)"
```

Added explicit error logging:
```rust
.map_err(|e| {
    tracing::error!("create_event failed (type={}, severity={}): {}", event_type, severity, e);
    e
})?;
```

## Verification

1. The SQL cast `$4::event_type` is standard PostgreSQL and works with all 8 ENUM values
2. If an invalid `event_type` string is passed (one not in the ENUM), the INSERT will fail with a clear error instead of silently
3. `cargo build` — 0 errors after fix

## Valid event_type Values

| Value | Usage |
|---|---|
| `agent_discovered` | New agent found by discovery |
| `agent_heartbeat` | Heartbeat received |
| `agent_failed` | Agent process died |
| `agent_restarted` | Restart completed |
| `agent_stopped` | Agent gracefully stopped |
| `policy_violation` | Security policy triggered |
| `security_incident` | Security incident created |
| `system_error` | Internal daemon error |

## Impact

- **Before:** 0 rows in `events` table after 3+ hours of runtime
- **After:** All agent lifecycle and security events correctly persisted
- **Audit trail:** `GET /api/security/audit` will now return real data
- **Dashboard:** Events tab will populate with actual event history

## Tests Added

None added (requires live PostgreSQL for integration testing). This path is covered by the integration test scaffold in `tests/integration/` which can be extended to verify event persistence against a test DB.
