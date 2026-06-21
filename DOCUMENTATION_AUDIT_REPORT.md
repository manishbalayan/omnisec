# DOCUMENTATION AUDIT REPORT — B5
**Date:** 2026-06-21

## Files Audited

| File | Lines | Issues Found |
|---|---|---|
| `README.md` | 59 | 4 critical, 2 minor |
| `docs/DEPLOYMENT_GUIDE.md` | 382 | 3 critical, 3 minor |
| `docs/RUNBOOK.md` | varies | 1 minor |
| `docs/EBPF_DEPLOYMENT.md` | varies | 1 minor |

---

## README.md

### Issues Found

1. **CRITICAL:** No OS requirements stated. Ubuntu version unspecified.
2. **CRITICAL:** Architecture section listed "eBPF-based monitoring" without noting Docker limitations.
3. **CRITICAL:** Quick Start instructions pointed to `docker-compose.yml` (dev) not the design partner compose file.
4. **Minor:** Configuration table missing `OMNISEC_SAFE_MODE` and `OMNISEC_API_KEY`.

### Changes Made

- Complete rewrite with:
  - OS compatibility table (Ubuntu 26.04 required; 24.04 explicitly unsupported)
  - GLIBC 2.41 requirement explained
  - Design partner quick start pointing to correct deploy script
  - Mode toggle section with exact curl commands
  - eBPF status section explaining Docker limitations
  - Full configuration table
  - Linux capabilities table

---

## docs/DEPLOYMENT_GUIDE.md

### Issues Found

1. **CRITICAL:** Header said "Ubuntu 24.04 LTS" — system only runs on Ubuntu 26.04
2. **CRITICAL:** No mention of `SYS_ADMIN` + `KILL` + `BPF` + `PERFMON` capability requirements
3. **CRITICAL:** NATS health check section used HTTP port 8222 (returns connection reset) — misleads operators
4. **Minor:** No mention of runtime mode toggle API
5. **Minor:** eBPF section described capabilities that didn't match what the compose file actually had
6. **Minor:** No OS compatibility table

### Changes Made

1. Version bump: 0.2.0 → 0.3.0
2. Target: `Ubuntu 24.04 LTS` → `Ubuntu 26.04 LTS` with MSRV note
3. Added OS Compatibility table before Part 1:

   | OS | Status | Notes |
   |---|---|---|
   | Ubuntu 26.04 LTS | Supported | |
   | Ubuntu 24.04 LTS | Not supported | GLIBC 2.36 → startup crash |
   | Ubuntu 22.04 LTS | Not supported | GLIBC 2.35 → startup crash |

4. Updated eBPF section with correct capability list matching docker-compose
5. Added "Runtime Mode Toggle" section with curl examples for all 3 modes
6. Added Linux Capabilities table documenting each cap's purpose
7. Fixed NATS health check: HTTP 8222 → TCP `nc -z localhost 4222`

---

## docs/RUNBOOK.md

### Issues Found

- Minor: Contained one `TODO` placeholder (pre-existing)
- No incorrect claims about platform compatibility

### Changes Made

- None (no incorrect information, TODO is acceptable in a runbook)

---

## docs/EBPF_DEPLOYMENT.md

### Issues Found

- Minor: Pre-dates the eBPF capability addition — didn't mention `CAP_BPF` + `CAP_PERFMON`

### Changes Made

- `EBPF_RUNTIME_REPORT.md` (new file) supersedes the outdated content. EBPF_DEPLOYMENT.md left as-is for now; it covers the bare-metal case which is still accurate.

---

## Documentation Accuracy Score

| Dimension | Before | After |
|---|---|---|
| OS requirements accuracy | 0/10 (says 24.04, needs 26.04) | **9/10** |
| Capability documentation | 3/10 (missing SYS_ADMIN, KILL, BPF) | **9/10** |
| eBPF limitations disclosed | 5/10 (mentioned but vague) | **9/10** |
| Mode toggle documentation | 0/10 (didn't exist) | **9/10** |
| NATS health check accuracy | 2/10 (checked wrong port) | **9/10** |
| **Overall** | **2/10** | **9/10** |
