#!/usr/bin/env bash
# Omnisec Design Partner Deployment Script
# Deploys all services defined in infra/docker/docker-compose.design-partner.yml
#
# Usage:
#   ./scripts/deploy-design-partner.sh               # Full deploy
#   ./scripts/deploy-design-partner.sh --skip-build  # Skip Rust workspace build
#   ./scripts/deploy-design-partner.sh --no-validate # Skip environment check

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="$REPO_ROOT/infra/docker/docker-compose.design-partner.yml"
SKIP_BUILD=false
NO_VALIDATE=false

for arg in "$@"; do
    case "$arg" in
        --skip-build)   SKIP_BUILD=true ;;
        --no-validate)  NO_VALIDATE=true ;;
        --help|-h)
            echo "Usage: $0 [--skip-build] [--no-validate]"
            exit 0
            ;;
    esac
done

# Docker Compose command — compose file uses relative paths (../..) that resolve
# correctly from the file's own directory; no --project-directory override needed.
DC="docker compose -f $COMPOSE_FILE"

# ── Colour helpers ─────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC}   $*"; }
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERR]${NC}  $*"; }
step() { echo ""; echo -e "${BLUE}═══ $* ═══${NC}"; }

echo ""
echo "╔══════════════════════════════════════╗"
echo "║   Omnisec Design Partner Deployment  ║"
echo "╚══════════════════════════════════════╝"
echo ""
info "Repository root: $REPO_ROOT"
info "Compose file:    $COMPOSE_FILE"

# ── Step 1: Validate environment ───────────────────────────────────────
step "Step 1: Environment Validation"
if [[ "$NO_VALIDATE" == true ]]; then
    warn "Skipping environment validation (--no-validate)"
else
    if bash "$REPO_ROOT/scripts/validate-environment.sh"; then
        ok "Environment validation passed"
    else
        err "Environment validation failed. Fix the issues above and retry."
        err "To skip validation (not recommended): $0 --no-validate"
        exit 1
    fi
fi

# ── Step 2: Pre-flight checks ──────────────────────────────────────────
step "Step 2: Pre-flight Checks"

if [[ ! -f "$COMPOSE_FILE" ]]; then
    err "Compose file not found: $COMPOSE_FILE"
    exit 1
fi
ok "Compose file found"

# Ensure postgres init.sql exists at workspace root (volume mount requires a file, not directory)
if [[ ! -f "$REPO_ROOT/postgres/init.sql" ]]; then
    info "Creating postgres/init.sql placeholder..."
    mkdir -p "$REPO_ROOT/postgres"
    echo "-- Schema managed by sqlx migrations at runtime" > "$REPO_ROOT/postgres/init.sql"
fi
ok "postgres/init.sql present"

# Docker daemon check
if ! docker info &>/dev/null; then
    err "Docker daemon is not running. Start it with: sudo systemctl start docker"
    exit 1
fi
ok "Docker daemon running"

# ── Step 3: Build Rust workspace (optional) ────────────────────────────
step "Step 3: Rust Workspace Build (pre-validation)"
if [[ "$SKIP_BUILD" == true ]]; then
    warn "Skipping Rust workspace build (--skip-build)"
    info "Docker builds will compile from source inside containers."
else
    if command -v cargo &>/dev/null; then
        info "Building Rust workspace to catch compilation errors early..."
        cd "$REPO_ROOT"
        if cargo build 2>&1 | tail -3; then
            ok "Rust workspace compiled successfully"
        else
            err "Rust workspace build failed. Fix compilation errors before deploying."
            err "To skip this step: $0 --skip-build"
            exit 1
        fi
    else
        warn "cargo not found — skipping local Rust build (Docker will compile inside containers)"
    fi
fi

# ── Step 4: Build Docker images ────────────────────────────────────────
step "Step 4: Building Docker Images"
info "Building all service images (this may take 10-20 minutes on first run)..."
info "Services: postgres, redis, nats, daemon, api, dashboard"

export DOCKER_BUILDKIT=1
if $DC build --progress=plain 2>&1; then
    ok "All images built successfully"
else
    err "Docker build failed. Check output above."
    err ""
    err "Common fixes:"
    err "  - Dashboard build error: verify apps/dashboard/Dockerfile exists"
    err "  - Rust compile error:    check cargo build output"
    err "  - Network error:         check internet connectivity"
    exit 1
fi

# ── Step 5: Start infrastructure ───────────────────────────────────────
step "Step 5: Starting Services"
info "Starting all services..."
$DC up -d
ok "Services started"

# ── Step 6: Wait for health ────────────────────────────────────────────
step "Step 6: Waiting for Service Health"

wait_healthy() {
    local container="$1" label="$2" max_secs="${3:-120}"
    local elapsed=0 interval=3
    info "Waiting for $label to be healthy..."
    while [[ $elapsed -lt $max_secs ]]; do
        status=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container" 2>/dev/null || echo "not_found")
        case "$status" in
            healthy|running)
                ok "$label is $status"
                return 0
                ;;
            unhealthy)
                err "$label is unhealthy"
                docker logs "$container" --tail 20
                return 1
                ;;
        esac
        sleep $interval
        elapsed=$((elapsed + interval))
        echo -n "."
    done
    echo ""
    err "$label: timed out after ${max_secs}s (status: $status)"
    docker logs "$container" --tail 20
    return 1
}

wait_healthy "omnisec-dp-postgres" "PostgreSQL" 120
wait_healthy "omnisec-dp-redis"    "Redis"      60

# Wait for NATS (no healthcheck — check if running)
info "Checking NATS..."
for i in $(seq 1 20); do
    if curl -sf http://localhost:8222/healthz &>/dev/null; then
        ok "NATS is running"
        break
    fi
    sleep 3
    if [[ $i -eq 20 ]]; then
        warn "NATS health check timed out (NATS may still be starting)"
    fi
done

# Wait for API
info "Waiting for API to be ready..."
for i in $(seq 1 40); do
    if curl -sf http://localhost:3000/ &>/dev/null; then
        ok "API is responding"
        break
    fi
    sleep 3
    if [[ $i -eq 40 ]]; then
        err "API did not respond after 120s"
        docker logs omnisec-dp-api --tail 30
        exit 1
    fi
done

# Wait for dashboard
info "Waiting for Dashboard to be ready..."
for i in $(seq 1 30); do
    if curl -sf http://localhost:3002/ &>/dev/null; then
        ok "Dashboard is responding"
        break
    fi
    sleep 3
    if [[ $i -eq 30 ]]; then
        warn "Dashboard did not respond after 90s (may still be starting)"
    fi
done

# ── Step 7: Verify health ──────────────────────────────────────────────
step "Step 7: Health Verification"

API_KEY="${OMNISEC_API_KEY:-dp-demo-key}"

info "API health check..."
API_HEALTH=$(curl -sf http://localhost:3000/ 2>/dev/null || echo '{"status":"unreachable"}')
echo "  API: $API_HEALTH"

info "PostgreSQL check..."
if docker exec omnisec-dp-postgres pg_isready -U postgres &>/dev/null; then
    ok "PostgreSQL: accepting connections"
else
    err "PostgreSQL: not ready"
fi

info "Redis check..."
REDIS_PONG=$(docker exec omnisec-dp-redis redis-cli ping 2>/dev/null || echo "FAILED")
if [[ "$REDIS_PONG" == "PONG" ]]; then
    ok "Redis: PONG"
else
    err "Redis: $REDIS_PONG"
fi

info "NATS check..."
NATS_STATUS=$(curl -sf http://localhost:8222/varz 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print('ok — server_id:' + d.get('server_id','?')[:12])" 2>/dev/null || echo "unreachable")
echo "  NATS: $NATS_STATUS"

info "API agents endpoint..."
AGENTS=$(curl -sf -H "X-API-Key: $API_KEY" http://localhost:3000/api/agents 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print('ok — discovered agents in DB')" 2>/dev/null || echo "unreachable or auth error")
echo "  Agents: $AGENTS"

# ── Step 8: Deployment summary ─────────────────────────────────────────
step "Deployment Summary"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                 OMNISEC DEPLOYMENT COMPLETE                  ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Service       URL / Endpoint"
echo "  ─────────────────────────────────────────────────────────────"
echo "  API           http://localhost:3000    (health: GET /)"
echo "  Dashboard     http://localhost:3002"
echo "  NATS          nats://localhost:4222"
echo "  NATS Monitor  http://localhost:8222"
echo "  PostgreSQL    localhost:5432           (db: omnisec)"
echo "  Redis         localhost:6379"
echo ""
echo "  API Key:      $API_KEY"
echo "  Safe Mode:    ENABLED (OMNISEC_SAFE_MODE=1 — enforcement is logged, not applied)"
echo ""
echo "  Authentication: curl -H \"X-API-Key: $API_KEY\" http://localhost:3000/api/agents"
echo ""
echo "  Running containers:"
$DC ps

echo ""
echo "  Logs:         docker logs omnisec-dp-daemon --tail 50"
echo "  Stop:         docker compose -f $COMPOSE_FILE down"
echo "  Restart:      docker compose -f $COMPOSE_FILE restart"
echo ""
