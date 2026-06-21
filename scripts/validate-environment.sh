#!/usr/bin/env bash
# Validates that the host meets all requirements to deploy Omnisec.
# Run as root or a user in the docker group.

set -euo pipefail

PASS="[PASS]"
FAIL="[FAIL]"
WARN="[WARN]"
ERRORS=0

pass()  { echo "$PASS $*"; }
fail()  { echo "$FAIL $*"; ((ERRORS++)); }
warn()  { echo "$WARN $*"; }
cmd_ok(){ command -v "$1" &>/dev/null; }

echo "=============================="
echo " Omnisec Environment Check"
echo "=============================="
echo ""

# ── OS ─────────────────────────────────────────────────────────────────
echo "── Operating System ──"
if cmd_ok lsb_release; then
    DISTRO=$(lsb_release -is 2>/dev/null || echo "unknown")
    VERSION=$(lsb_release -rs 2>/dev/null || echo "unknown")
    if [[ "$DISTRO" == "Ubuntu" && "$VERSION" == "24.04" ]]; then
        pass "Ubuntu 24.04 LTS"
    elif [[ "$DISTRO" == "Ubuntu" ]]; then
        warn "Ubuntu $VERSION (tested on 24.04; may work on 22.04+)"
    else
        fail "OS: $DISTRO $VERSION (Ubuntu 24.04 required)"
    fi
else
    fail "lsb_release not found — cannot determine OS"
fi

# ── Kernel ─────────────────────────────────────────────────────────────
echo ""
echo "── Kernel ──"
KERNEL=$(uname -r)
KMAJ=$(echo "$KERNEL" | cut -d. -f1)
KMIN=$(echo "$KERNEL" | cut -d. -f2)
if [[ $KMAJ -gt 5 ]] || { [[ $KMAJ -eq 5 ]] && [[ $KMIN -ge 8 ]]; }; then
    pass "Kernel $KERNEL (>= 5.8, eBPF full support)"
elif [[ $KMAJ -eq 5 ]] && [[ $KMIN -ge 4 ]]; then
    warn "Kernel $KERNEL (5.4-5.7: limited eBPF; recommend >= 5.8)"
else
    fail "Kernel $KERNEL (< 5.4: eBPF unsupported)"
fi

# Check BTF (required for eBPF CO-RE)
if [[ -f /sys/kernel/btf/vmlinux ]]; then
    pass "BTF: /sys/kernel/btf/vmlinux present (eBPF CO-RE supported)"
else
    warn "BTF: /sys/kernel/btf/vmlinux missing (eBPF will use /proc fallback)"
fi

# ── Container runtime ──────────────────────────────────────────────────
echo ""
echo "── Container Runtime ──"
if cmd_ok docker; then
    DOCKER_VER=$(docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)
    pass "Docker $DOCKER_VER"
    if docker info &>/dev/null; then
        pass "Docker daemon: running"
    else
        fail "Docker daemon: not running (run: sudo systemctl start docker)"
    fi
else
    fail "Docker: not installed (run: curl -fsSL https://get.docker.com | sh)"
fi

if docker compose version &>/dev/null 2>&1; then
    DC_VER=$(docker compose version --short 2>/dev/null || docker compose version | grep -oP '\d+\.\d+\.\d+' | head -1)
    pass "Docker Compose v$DC_VER"
else
    fail "Docker Compose: not found (requires docker compose plugin v2)"
fi

# ── Build tools ────────────────────────────────────────────────────────
echo ""
echo "── Build Tools ──"
if cmd_ok git; then
    pass "Git: $(git --version | awk '{print $3}')"
else
    fail "Git: not installed (run: sudo apt-get install -y git)"
fi

if cmd_ok rustc; then
    pass "Rust: $(rustc --version)"
else
    warn "Rust: not installed (needed for local builds only; Docker builds include Rust)"
fi

if cmd_ok cargo; then
    pass "Cargo: $(cargo --version)"
else
    warn "Cargo: not installed (needed for local builds only)"
fi

if cmd_ok clang; then
    pass "Clang: $(clang --version | head -1)"
else
    warn "Clang: not installed (needed for eBPF compilation — run: sudo apt-get install -y clang)"
fi

# ── Network / Security tools ───────────────────────────────────────────
echo ""
echo "── Network & Security Tools ──"
if cmd_ok nft; then
    pass "nftables (nft): $(nft --version 2>/dev/null | head -1)"
else
    warn "nftables: not installed (run: sudo apt-get install -y nftables)"
fi

if cmd_ok bpftool; then
    pass "bpftool: $(bpftool version 2>/dev/null | head -1)"
else
    warn "bpftool: not installed (run: sudo apt-get install -y linux-tools-common linux-tools-$(uname -r))"
fi

# ── eBPF / cgroup support ──────────────────────────────────────────────
echo ""
echo "── eBPF & cgroup Support ──"
if [[ -d /sys/fs/bpf ]]; then
    pass "eBPF filesystem: /sys/fs/bpf mounted"
else
    fail "eBPF filesystem: /sys/fs/bpf not mounted"
    echo "       Fix: sudo mount -t bpf bpffs /sys/fs/bpf"
fi

if [[ -d /sys/fs/cgroup ]]; then
    CGROUP_VER="v1"
    [[ -f /sys/fs/cgroup/cgroup.controllers ]] && CGROUP_VER="v2"
    pass "cgroup: /sys/fs/cgroup present (${CGROUP_VER})"
else
    fail "cgroup: /sys/fs/cgroup not found"
fi

# CAP_BPF check — verify kernel allows unprivileged eBPF or we are root
if [[ $EUID -eq 0 ]]; then
    pass "CAP_BPF: running as root (all eBPF operations permitted)"
elif [[ -f /proc/sys/kernel/unprivileged_bpf_disabled ]]; then
    BPF_DISABLED=$(cat /proc/sys/kernel/unprivileged_bpf_disabled)
    if [[ "$BPF_DISABLED" == "0" ]]; then
        pass "CAP_BPF: unprivileged eBPF enabled (kernel.unprivileged_bpf_disabled=0)"
    else
        warn "CAP_BPF: unprivileged eBPF restricted (kernel.unprivileged_bpf_disabled=$BPF_DISABLED)"
        echo "       Docker daemon will grant CAP_BPF to containers via cap_add"
    fi
else
    warn "CAP_BPF: cannot determine BPF privilege level; Docker will manage via cap_add"
fi

# CAP_NET_ADMIN check
if ip link show lo &>/dev/null 2>&1; then
    pass "CAP_NET_ADMIN: network interface access OK"
else
    fail "CAP_NET_ADMIN: cannot access network interfaces (are you in a restricted namespace?)"
fi

# ── /proc access ───────────────────────────────────────────────────────
echo ""
echo "── Process Filesystem ──"
if [[ -d /proc && -r /proc/self/status ]]; then
    pass "/proc: accessible (required for daemon agent discovery)"
else
    fail "/proc: not accessible"
fi

# ── systemd ────────────────────────────────────────────────────────────
echo ""
echo "── systemd ──"
if cmd_ok systemctl; then
    pass "systemd: $(systemctl --version | head -1)"
else
    warn "systemd: not found (optional; Omnisec runs without it)"
fi

# ── Port availability ──────────────────────────────────────────────────
echo ""
echo "── Required Port Availability ──"
check_port() {
    local port=$1 label=$2
    if ss -tlnp "sport = :${port}" 2>/dev/null | grep -q ":${port}"; then
        warn "Port $port ($label): already in use — may conflict"
    else
        pass "Port $port ($label): available"
    fi
}
check_port 3000 "omnisec-api"
check_port 3002 "omnisec-dashboard"
check_port 4222 "nats"
check_port 5432 "postgres"
check_port 6379 "redis"
check_port 8222 "nats-monitoring"

# ── Disk space ─────────────────────────────────────────────────────────
echo ""
echo "── Disk Space ──"
AVAIL_KB=$(df -k . | tail -1 | awk '{print $4}')
AVAIL_GB=$(awk "BEGIN { printf \"%.1f\", $AVAIL_KB/1048576 }")
if [[ $AVAIL_KB -gt 10485760 ]]; then
    pass "Disk space: ${AVAIL_GB}GB available (>= 10GB required)"
else
    fail "Disk space: ${AVAIL_GB}GB available (need >= 10GB for Docker images and data)"
fi

# ── Summary ────────────────────────────────────────────────────────────
echo ""
echo "=============================="
if [[ $ERRORS -eq 0 ]]; then
    echo "ENVIRONMENT READY"
    echo ""
    echo "Proceed with: ./scripts/deploy-design-partner.sh"
    exit 0
else
    echo "ENVIRONMENT NOT READY ($ERRORS check(s) failed)"
    echo ""
    echo "Resolve the [FAIL] items above before deploying."
    exit 1
fi
