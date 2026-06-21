# Omnisec Deployment Context Fix Report

**Date:** 2026-06-21  
**File fixed:** `infra/docker/docker-compose.design-partner.yml`  
**Script updated:** `scripts/deploy-design-partner.sh`

---

## Root Cause

Docker Compose resolves all relative paths in a compose file **relative to the directory that contains the compose file**, not relative to the current working directory or the repository root.

The compose file lives at:
```
infra/docker/docker-compose.design-partner.yml
```

Its resolution base is therefore:
```
infra/docker/
```

All three built services and the postgres volume mount used relative paths that were written as if the compose file were at the repository root. When Docker Compose expanded them, every path was anchored inside `infra/docker/`, pointing to directories that do not exist.

---

## Incorrect Paths (Before Fix)

### daemon

```yaml
# BROKEN — resolves to infra/docker/ (no Dockerfile there)
build:
  context: .
  dockerfile: services/daemon/Dockerfile
```

Resolved by Docker Compose:
```
context:    /home/ice_test/omnisec/infra/docker
dockerfile: /home/ice_test/omnisec/infra/docker/services/daemon/Dockerfile  ← does not exist
```

### api

```yaml
# BROKEN — resolves to infra/docker/ (no Dockerfile there)
build:
  context: .
  dockerfile: apps/api/Dockerfile
```

Resolved by Docker Compose:
```
context:    /home/ice_test/omnisec/infra/docker
dockerfile: /home/ice_test/omnisec/infra/docker/apps/api/Dockerfile  ← does not exist
```

### dashboard

```yaml
# BROKEN — context resolves inside infra/docker/; dockerfile also wrong
build:
  context: apps/dashboard
  dockerfile: apps/dashboard/Dockerfile
```

Resolved by Docker Compose:
```
context:    /home/ice_test/omnisec/infra/docker/apps/dashboard  ← does not exist
dockerfile: /home/ice_test/omnisec/infra/docker/apps/dashboard/Dockerfile  ← does not exist
```

> This is the error observed on Ubuntu: `dashboard build context: /home/ice_test/omnisec/infra/docker/apps/dashboard`

### postgres volume mount

```yaml
# BROKEN — resolves to infra/docker/postgres/init.sql (does not exist)
volumes:
  - ./postgres/init.sql:/docker-entrypoint-initdb.d/init.sql
```

Resolved by Docker Compose:
```
source: /home/ice_test/omnisec/infra/docker/postgres/init.sql  ← does not exist
```

---

## Corrected Paths (After Fix)

The fix uses `../..` to traverse from `infra/docker/` up two levels to the repository root, and `../../apps/dashboard` to reach the dashboard source.

### daemon

```yaml
build:
  context: ../..
  dockerfile: services/daemon/Dockerfile
```

Resolves to:
```
context:    /home/ice_test/omnisec                              ✓
dockerfile: /home/ice_test/omnisec/services/daemon/Dockerfile  ✓
```

### api

```yaml
build:
  context: ../..
  dockerfile: apps/api/Dockerfile
```

Resolves to:
```
context:    /home/ice_test/omnisec                          ✓
dockerfile: /home/ice_test/omnisec/apps/api/Dockerfile      ✓
```

### dashboard

```yaml
build:
  context: ../../apps/dashboard
  dockerfile: Dockerfile
```

Resolves to:
```
context:    /home/ice_test/omnisec/apps/dashboard            ✓
dockerfile: /home/ice_test/omnisec/apps/dashboard/Dockerfile ✓
```

Note: `dockerfile: Dockerfile` is correct here because the Dockerfile lives directly inside the build context directory (`apps/dashboard/`). The previous value `apps/dashboard/Dockerfile` would have been interpreted relative to the build context, producing a non-existent path `apps/dashboard/apps/dashboard/Dockerfile`.

### postgres volume mount

```yaml
volumes:
  - ../../postgres/init.sql:/docker-entrypoint-initdb.d/init.sql
```

Resolves to:
```
source: /home/ice_test/omnisec/postgres/init.sql  ✓
```

---

## deploy-design-partner.sh Update

The previous version of the deploy script worked around the broken compose file by forcing `--project-directory` to the workspace root:

```bash
# OLD (workaround — no longer needed)
DC="docker compose --project-directory $REPO_ROOT -f $COMPOSE_FILE"
```

With the compose file now self-consistent, the workaround is removed:

```bash
# NEW (correct — compose file resolves its own paths)
DC="docker compose -f $COMPOSE_FILE"
```

---

## docker compose config Verification

Running `docker-compose -f infra/docker/docker-compose.design-partner.yml config` after the fix produces the following resolved paths (shown on macOS; on Ubuntu `/Users/manish/desktop/omnisec` → `/home/ice_test/omnisec`):

```yaml
services:
  api:
    build:
      context: /Users/manish/desktop/omnisec          # ✓ workspace root
      dockerfile: apps/api/Dockerfile

  daemon:
    build:
      context: /Users/manish/desktop/omnisec          # ✓ workspace root
      dockerfile: services/daemon/Dockerfile

  dashboard:
    build:
      context: /Users/manish/desktop/omnisec/apps/dashboard   # ✓
      dockerfile: Dockerfile

  postgres:
    volumes:
      - type: bind
        source: /Users/manish/desktop/omnisec/postgres/init.sql  # ✓
        target: /docker-entrypoint-initdb.d/init.sql
```

All four paths resolve to existing filesystem locations.

---

## Summary of Changes

| File | Lines changed | Change |
|---|---|---|
| `infra/docker/docker-compose.design-partner.yml` | 4 | Fixed `context` for daemon, api, dashboard; fixed `dockerfile` for dashboard; fixed postgres volume path |
| `scripts/deploy-design-partner.sh` | 3 | Removed `--project-directory` workaround; updated stop/restart hint commands |

No application code, runtime logic, security logic, or enforcement logic was modified.

---

## Deployment Command (Ubuntu)

After pulling/rsyncing these changes, deploy with the standard invocation:

```bash
cd ~/omnisec
docker compose -f infra/docker/docker-compose.design-partner.yml up -d --build
```

Or via the script:

```bash
./scripts/deploy-design-partner.sh
```
