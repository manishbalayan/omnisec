# ENFORCEMENT VALIDATION REPORT — B2
**Date:** 2026-06-21

## Root Cause

The daemon container in `docker-compose.design-partner.yml` was missing critical Linux capabilities required for enforcement actions:

| Capability | Required By | Was Present? |
|---|---|---|
| `NET_ADMIN` | nftables (`nft add rule`) | Yes |
| `SYS_PTRACE` | /proc inspection | Yes |
| `DAC_READ_SEARCH` | cross-user /proc reads | Yes |
| `SYS_ADMIN` | cgroup writes (`/sys/fs/cgroup`) | **NO** |
| `KILL` | `libc::kill(SIGSTOP/SIGKILL)` | **NO** |
| `BPF` | eBPF program loading | **NO** |
| `PERFMON` | eBPF tracepoint attachment | **NO** |

Additionally:
- `/sys/fs/cgroup` was not mounted into the container — cgroup writes went nowhere
- `cgroupns: host` was absent — even with SYS_ADMIN, cgroup writes would target a separate container cgroup namespace, not the host tree
- `/sys/kernel/btf` was not mounted — BTF type info unavailable to eBPF loader

## Code That Was Blocked

### nftables (NET_ADMIN — already present, worked)
```rust
// crates/runtime/src/network.rs
Command::new("nft").args(&["add", "rule", "inet", "omnisec", ...]).output()
```

### cgroup throttle (SYS_ADMIN — was MISSING)
```rust
// crates/runtime/src/resource.rs
fs::write("/sys/fs/cgroup/omnisec/cpu.max", "50000 100000")
// → PermissionDenied without SYS_ADMIN + cgroup mount
```

### SIGSTOP quarantine (KILL — was MISSING)
```rust
// crates/runtime/src/process.rs
unsafe { libc::kill(pid as i32, libc::SIGSTOP); }
// → EPERM without CAP_KILL for cross-process signals
```

## Fix Applied

```yaml
# docker-compose.design-partner.yml — daemon service
cap_add:
  - SYS_PTRACE          # was present
  - NET_ADMIN           # was present
  - DAC_READ_SEARCH     # was present
  - SYS_ADMIN           # NEW — cgroup enforcement
  - KILL                # NEW — SIGSTOP/SIGKILL quarantine
  - BPF                 # NEW — eBPF program loading
  - PERFMON             # NEW — eBPF tracepoint attachment

cgroupns: host          # NEW — host cgroup namespace

volumes:
  - /proc:/host/proc:ro               # was present
  - /sys/fs/cgroup:/sys/fs/cgroup:rw  # NEW — cgroup enforcement
  - /sys/fs/bpf:/sys/fs/bpf:rw        # NEW — eBPF pin filesystem
  - /sys/kernel/btf:/sys/kernel/btf:ro # NEW — BTF for eBPF CO-RE
```

## Enforcement Path Verification

After redeployment, verify capabilities are granted:

```bash
docker inspect omnisec-dp-daemon --format '{{.HostConfig.CapAdd}}'
# Expected: [SYS_PTRACE NET_ADMIN DAC_READ_SEARCH SYS_ADMIN KILL BPF PERFMON]
```

Verify cgroup mount is live:
```bash
docker exec omnisec-dp-daemon ls /sys/fs/cgroup/
# Expected: listing of cgroup controllers (cgroup.controllers, cpu, memory, etc.)
```

## Enforcement Testing (requires OMNISEC_SAFE_MODE=0)

To test enforcement with a real agent:

```bash
# 1. Disable safe mode via API
curl -X POST -H "X-API-Key: dp-demo-key" \
  -H "Content-Type: application/json" \
  -d '{"mode":"enforcement"}' \
  http://localhost:3000/api/config/mode

# 2. Check daemon log for mode change acknowledgment
docker logs omnisec-dp-daemon --tail 5

# 3. Test nftables block (requires a running agent making network connections)
# The daemon will automatically apply nftables rules when anomalies are detected

# 4. Verify nftables rules are being created
docker exec omnisec-dp-daemon nft list ruleset 2>/dev/null | head -20
```

## Security Note

`SYS_ADMIN` is a broad capability. For production deployments, consider:
- Restricting to only what's needed via seccomp profile
- Using rootless Docker with user namespaces for non-enforcement workloads
- Auditing all cgroup writes via the `security_audit_trail` table

The design partner deployment runs with `OMNISEC_SAFE_MODE=1` by default — no enforcement is applied until the mode is explicitly changed.
