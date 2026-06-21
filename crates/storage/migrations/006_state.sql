-- Operational State Persistence (Sprint 1 — Daemon restart survival)
-- Stores runtime state that must survive daemon restarts.
-- All tables use upsert semantics for idempotent recovery.

-- AgentRuntimeIdentity persistence (PID → Agent mapping survival)
CREATE TABLE state_agent_identities (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    agent_id UUID NOT NULL UNIQUE,
    pid INTEGER NOT NULL,
    ppid INTEGER NOT NULL DEFAULT 0,
    agent_name VARCHAR(255) NOT NULL,
    comm VARCHAR(255) NOT NULL DEFAULT '',
    executable_path TEXT,
    process_tree_depth INTEGER NOT NULL DEFAULT 0,
    parent_agent_id UUID,
    child_pids INTEGER[] NOT NULL DEFAULT '{}',
    first_seen TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_seen TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    is_child_process BOOLEAN NOT NULL DEFAULT false,
    is_orphan BOOLEAN NOT NULL DEFAULT false,
    version INTEGER NOT NULL DEFAULT 1,
    framework VARCHAR(100),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(pid)
);

-- Restart state per agent (counts, cooldown, last attempt)
CREATE TABLE state_restart_state (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    pid INTEGER NOT NULL UNIQUE,
    agent_name VARCHAR(255) NOT NULL,
    attempt_count INTEGER NOT NULL DEFAULT 0,
    last_attempt_at TIMESTAMPTZ,
    cooldown_until TIMESTAMPTZ,
    consecutive_failures INTEGER NOT NULL DEFAULT 0,
    status VARCHAR(16) NOT NULL DEFAULT 'Healthy',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Recovery engine actions (pending auto-recoveries that survive restarts)
CREATE TABLE state_recovery_actions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    action_id UUID NOT NULL UNIQUE,
    action_type VARCHAR(64) NOT NULL,
    target VARCHAR(512) NOT NULL,
    expires_at TIMESTAMPTZ,
    rollback_action VARCHAR(64) NOT NULL,
    rolled_back BOOLEAN NOT NULL DEFAULT false,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Enforcement lists (dynamic allow/block — replaces hardcoded defaults)
CREATE TABLE state_enforcement_lists (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    list_type VARCHAR(16) NOT NULL CHECK (list_type IN ('allow', 'block', 'known_exec', 'blocked_exec', 'sensitive_path')),
    target VARCHAR(512) NOT NULL,
    category VARCHAR(64) NOT NULL DEFAULT 'default',
    reason TEXT NOT NULL DEFAULT '',
    created_by VARCHAR(255) NOT NULL DEFAULT 'system',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(list_type, target)
);

-- Operational configuration (key-value for daemon settings)
CREATE TABLE state_config (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    key VARCHAR(255) NOT NULL UNIQUE,
    value JSONB NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_state_identities_agent ON state_agent_identities(agent_id);
CREATE INDEX idx_state_identities_pid ON state_agent_identities(pid);
CREATE INDEX idx_state_restart_pid ON state_restart_state(pid);
CREATE INDEX idx_state_recovery_action_id ON state_recovery_actions(action_id);
CREATE INDEX idx_state_recovery_expires ON state_recovery_actions(expires_at);
CREATE INDEX idx_state_enforcement_type ON state_enforcement_lists(list_type);
