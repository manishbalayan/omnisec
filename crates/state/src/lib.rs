//! # OMNISEC State Manager
//!
//! Persists and recovers all operational state across daemon restarts.
//! Called during daemon startup (before tasks) and periodically during operation.
//!
//! ## Recovery ordering
//!
//! 1. Agent identities (PID→Agent mapping)
//! 2. Enforcement lists (allow/block/known/blocked execs, sensitive paths)
//! 3. Restart state (per-agent restart counts)
//! 4. Recovery actions (pending auto-recoveries)
//!
//! ## Design principles
//!
//! - All recovery happens BEFORE daemon tasks start
//! - Missing tables/data = graceful skip (not a startup failure)
//! - Persistence is best-effort (no critical path blocking)
//! - Uses upsert semantics throughout for idempotent recovery

use anyhow::Result;
use chrono::Utc;
use serde_json::Value;
use sqlx::PgPool;
use uuid::Uuid;

use omnisec_identity::AgentRuntimeIdentity;

// ---------------------------------------------------------------------------
// StateManager
// ---------------------------------------------------------------------------

pub struct StateManager {
    pool: PgPool,
}

impl StateManager {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    // =====================================================================
    // Full recovery — call once at daemon startup BEFORE tasks are spawned
    // =====================================================================

    /// Recover ALL persisted state. Returns a StateSnapshot that can be used
    /// to hydrate all in-memory engines.
    pub async fn recover_all(&self) -> Result<StateSnapshot> {
        tracing::info!("StateManager: recovering all persisted state");

        let identities = self.recover_identities().await?;
        let enforcement_lists = self.recover_enforcement_lists().await?;
        let restart_state = self.recover_restart_state().await?;
        let recovery_actions = self.recover_recovery_actions().await?;

        tracing::info!(
            "StateManager: recovered {} identities, {} enforcement items, {} restart entries, {} recovery actions",
            identities.len(),
            enforcement_lists.len(),
            restart_state.len(),
            recovery_actions.len(),
        );

        Ok(StateSnapshot {
            identities,
            enforcement_lists,
            restart_state,
            recovery_actions,
        })
    }

    // =====================================================================
    // Agent identities
    // =====================================================================

    /// Persist a batch of agent identities (upsert).
    /// Called during daemon shutdown or periodic checkpoint.
    pub async fn persist_identities(&self, identities: &[AgentRuntimeIdentity]) -> Result<()> {
        for identity in identities {
            self.upsert_identity(identity).await?;
        }
        Ok(())
    }

    /// Upsert a single agent identity.
    pub async fn upsert_identity(&self, identity: &AgentRuntimeIdentity) -> Result<()> {
        let child_pids: Vec<i32> = identity.child_pids.iter().map(|p| *p as i32).collect();
        sqlx::query(
            r#"INSERT INTO state_agent_identities
               (agent_id, pid, ppid, agent_name, comm, executable_path, process_tree_depth,
                parent_agent_id, child_pids, first_seen, last_seen, is_child_process,
                is_orphan, version, framework, updated_at)
               VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, NOW())
               ON CONFLICT (pid)
               DO UPDATE SET
                   agent_name = $4, comm = $5, executable_path = $6,
                   process_tree_depth = $7, parent_agent_id = $8,
                   child_pids = $9, last_seen = $11, is_orphan = $13,
                   version = $14, framework = $15, updated_at = NOW()"#,
        )
        .bind(identity.agent_id)
        .bind(identity.pid as i32)
        .bind(identity.ppid as i32)
        .bind(&identity.agent_name)
        .bind(&identity.comm)
        .bind(&identity.executable_path)
        .bind(identity.process_tree_depth as i32)
        .bind(identity.parent_agent_id)
        .bind(&child_pids)
        .bind(identity.first_seen)
        .bind(identity.last_seen)
        .bind(identity.is_child_process)
        .bind(identity.is_orphan)
        .bind(identity.version as i32)
        .bind(&identity.framework)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Load all persisted identities from DB.
    pub async fn recover_identities(&self) -> Result<Vec<AgentRuntimeIdentity>> {
        let rows = sqlx::query_as::<_, IdentityRow>(
            r#"SELECT agent_id, pid, ppid, agent_name, comm, executable_path,
                      process_tree_depth, parent_agent_id, child_pids,
                      first_seen, last_seen, is_child_process, is_orphan,
                      version, framework
               FROM state_agent_identities
               ORDER BY first_seen DESC"#,
        )
        .fetch_all(&self.pool)
        .await?;

        Ok(rows.into_iter().filter_map(|r| r.to_identity()).collect())
    }

    /// Remove stale identities (PIDs no longer alive).
    pub async fn prune_stale_identities(&self, active_pids: &[u32]) -> Result<u64> {
        let result = sqlx::query(
            r#"DELETE FROM state_agent_identities WHERE pid != ALL($1)"#,
        )
        .bind(active_pids.iter().map(|p| *p as i32).collect::<Vec<i32>>())
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected())
    }

    // =====================================================================
    // Enforcement lists (allow, block, known/blocked execs, sensitive paths)
    // =====================================================================

    /// Persist a batch of enforcement list entries.
    pub async fn persist_enforcement_lists(&self, list_type: &str, entries: &[String]) -> Result<()> {
        for entry in entries {
            sqlx::query(
                r#"INSERT INTO state_enforcement_lists (list_type, target)
                   VALUES ($1, $2)
                   ON CONFLICT (list_type, target) DO NOTHING"#,
            )
            .bind(list_type)
            .bind(entry)
            .execute(&self.pool)
            .await?;
        }
        Ok(())
    }

    /// Load all enforcement list entries of a given type.
    pub async fn recover_enforcement_list(&self, list_type: &str) -> Result<Vec<String>> {
        let rows: Vec<(String,)> = sqlx::query_as(
            r#"SELECT target FROM state_enforcement_lists
               WHERE list_type = $1 ORDER BY target"#,
        )
        .bind(list_type)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows.into_iter().map(|r| r.0).collect())
    }

    /// Load ALL enforcement lists.
    pub async fn recover_enforcement_lists(&self) -> Result<EnforcementLists> {
        Ok(EnforcementLists {
            allow_destinations: self.recover_enforcement_list("allow").await?,
            block_destinations: self.recover_enforcement_list("block").await?,
            known_executables: self.recover_enforcement_list("known_exec").await?,
            blocked_executables: self.recover_enforcement_list("blocked_exec").await?,
            sensitive_paths: self.recover_enforcement_list("sensitive_path").await?,
        })
    }

    /// Add a single enforcement list entry.
    pub async fn add_enforcement_entry(
        &self,
        list_type: &str,
        target: &str,
        reason: &str,
        created_by: &str,
    ) -> Result<()> {
        sqlx::query(
            r#"INSERT INTO state_enforcement_lists (list_type, target, reason, created_by)
               VALUES ($1, $2, $3, $4)
               ON CONFLICT (list_type, target)
               DO UPDATE SET reason = $3, created_by = $4"#,
        )
        .bind(list_type)
        .bind(target)
        .bind(reason)
        .bind(created_by)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Remove a single enforcement list entry.
    pub async fn remove_enforcement_entry(&self, list_type: &str, target: &str) -> Result<u64> {
        let result = sqlx::query(
            r#"DELETE FROM state_enforcement_lists WHERE list_type = $1 AND target = $2"#,
        )
        .bind(list_type)
        .bind(target)
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected())
    }

    // =====================================================================
    // Restart state
    // =====================================================================

    /// Persist restart state for an agent.
    pub async fn upsert_restart_state(&self, pid: u32, agent_name: &str, attempt_count: u32, consecutive_failures: u32, status: &str) -> Result<()> {
        sqlx::query(
            r#"INSERT INTO state_restart_state (pid, agent_name, attempt_count, consecutive_failures, status, updated_at)
               VALUES ($1, $2, $3, $4, $5, NOW())
               ON CONFLICT (pid)
               DO UPDATE SET
                   agent_name = $2, attempt_count = $3, consecutive_failures = $4,
                   status = $5, last_attempt_at = NOW(), updated_at = NOW()"#,
        )
        .bind(pid as i32)
        .bind(agent_name)
        .bind(attempt_count as i32)
        .bind(consecutive_failures as i32)
        .bind(status)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Load all restart state.
    pub async fn recover_restart_state(&self) -> Result<Vec<RestartStateEntry>> {
        let rows = sqlx::query_as::<_, RestartRow>(
            r#"SELECT pid, agent_name, attempt_count, consecutive_failures, status, last_attempt_at, cooldown_until
               FROM state_restart_state ORDER BY agent_name"#,
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows.into_iter().map(|r| r.to_entry()).collect())
    }

    // =====================================================================
    // Recovery actions (pending auto-recoveries)
    // =====================================================================

    /// Persist a recovery action.
    pub async fn upsert_recovery_action(&self, action_id: Uuid, action_type: &str, target: &str, duration_secs: Option<u64>, rollback_action: &str) -> Result<()> {
        let expires_at = duration_secs.map(|s| Utc::now() + chrono::Duration::seconds(s as i64));
        sqlx::query(
            r#"INSERT INTO state_recovery_actions (action_id, action_type, target, expires_at, rollback_action)
               VALUES ($1, $2, $3, $4, $5)
               ON CONFLICT (action_id) DO NOTHING"#,
        )
        .bind(action_id)
        .bind(action_type)
        .bind(target)
        .bind(expires_at)
        .bind(rollback_action)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Mark a recovery action as rolled back.
    pub async fn mark_recovery_rolled_back(&self, action_id: Uuid) -> Result<()> {
        sqlx::query(
            r#"UPDATE state_recovery_actions SET rolled_back = true WHERE action_id = $1"#,
        )
        .bind(action_id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Load all pending (non-rolled-back) recovery actions.
    pub async fn recover_recovery_actions(&self) -> Result<Vec<RecoveryActionEntry>> {
        let rows = sqlx::query_as::<_, RecoveryRow>(
            r#"SELECT action_id, action_type, target, expires_at, rollback_action, created_at
               FROM state_recovery_actions WHERE rolled_back = false
               ORDER BY created_at"#,
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows.into_iter().map(|r| r.to_entry()).collect())
    }

    // =====================================================================
    // Operational config (key-value)
    // =====================================================================

    /// Set a configuration value.
    pub async fn set_config(&self, key: &str, value: Value, description: &str) -> Result<()> {
        sqlx::query(
            r#"INSERT INTO state_config (key, value, description, updated_at)
               VALUES ($1, $2, $3, NOW())
               ON CONFLICT (key)
               DO UPDATE SET value = $2, description = $3, updated_at = NOW()"#,
        )
        .bind(key)
        .bind(&value)
        .bind(description)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Get a configuration value.
    pub async fn get_config(&self, key: &str) -> Result<Option<Value>> {
        let row: Option<(Value,)> = sqlx::query_as(
            r#"SELECT value FROM state_config WHERE key = $1"#,
        )
        .bind(key)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|r| r.0))
    }

    /// Get all configuration as a JSON map.
    pub async fn get_all_config(&self) -> Result<Value> {
        let rows: Vec<(String, Value)> = sqlx::query_as(
            r#"SELECT key, value FROM state_config ORDER BY key"#,
        )
        .fetch_all(&self.pool)
        .await?;
        let map: std::collections::HashMap<String, Value> = rows.into_iter().collect();
        Ok(serde_json::to_value(map)?)
    }
}

// ---------------------------------------------------------------------------
// Snapshot returned by recover_all()
// ---------------------------------------------------------------------------

/// A complete snapshot of all recovered state from the database.
/// Used to hydrate all in-memory engines at daemon startup.
#[derive(Debug, Clone)]
pub struct StateSnapshot {
    pub identities: Vec<AgentRuntimeIdentity>,
    pub enforcement_lists: EnforcementLists,
    pub restart_state: Vec<RestartStateEntry>,
    pub recovery_actions: Vec<RecoveryActionEntry>,
}

/// All enforcement/allow/block lists from the database.
#[derive(Debug, Clone, Default)]
pub struct EnforcementLists {
    pub allow_destinations: Vec<String>,
    pub block_destinations: Vec<String>,
    pub known_executables: Vec<String>,
    pub blocked_executables: Vec<String>,
    pub sensitive_paths: Vec<String>,
}

impl EnforcementLists {
    /// Total number of items across all list types.
    pub fn len(&self) -> usize {
        self.allow_destinations.len()
            + self.block_destinations.len()
            + self.known_executables.len()
            + self.blocked_executables.len()
            + self.sensitive_paths.len()
    }

    /// Returns `true` if all lists are empty.
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

/// Restart state entry for a single agent.
#[derive(Debug, Clone)]
pub struct RestartStateEntry {
    pub pid: u32,
    pub agent_name: String,
    pub attempt_count: u32,
    pub consecutive_failures: u32,
    pub status: String,
    pub last_attempt_at: Option<chrono::DateTime<chrono::Utc>>,
    pub cooldown_until: Option<chrono::DateTime<chrono::Utc>>,
}

/// Recovery action entry.
#[derive(Debug, Clone)]
pub struct RecoveryActionEntry {
    pub action_id: Uuid,
    pub action_type: String,
    pub target: String,
    pub expires_at: Option<chrono::DateTime<chrono::Utc>>,
    pub rollback_action: String,
    pub created_at: chrono::DateTime<chrono::Utc>,
}

// ---------------------------------------------------------------------------
// Internal row types for DB deserialization
// ---------------------------------------------------------------------------

#[derive(Debug, sqlx::FromRow)]
struct IdentityRow {
    agent_id: Uuid,
    pid: i32,
    ppid: i32,
    agent_name: String,
    comm: String,
    executable_path: Option<String>,
    process_tree_depth: i32,
    parent_agent_id: Option<Uuid>,
    child_pids: Vec<i32>,
    first_seen: chrono::DateTime<chrono::Utc>,
    last_seen: chrono::DateTime<chrono::Utc>,
    is_child_process: bool,
    is_orphan: bool,
    version: i32,
    framework: Option<String>,
}

impl IdentityRow {
    fn to_identity(self) -> Option<AgentRuntimeIdentity> {
        Some(AgentRuntimeIdentity {
            agent_id: self.agent_id,
            pid: self.pid as u32,
            ppid: self.ppid as u32,
            agent_name: self.agent_name,
            comm: self.comm,
            executable_path: self.executable_path,
            process_tree_depth: self.process_tree_depth as u32,
            parent_agent_id: self.parent_agent_id,
            child_pids: self.child_pids.into_iter().map(|p| p as u32).collect(),
            first_seen: self.first_seen,
            last_seen: self.last_seen,
            is_child_process: self.is_child_process,
            is_orphan: self.is_orphan,
            version: self.version as u32,
            framework: self.framework,
        })
    }
}

#[derive(Debug, sqlx::FromRow)]
struct RestartRow {
    pid: i32,
    agent_name: String,
    attempt_count: i32,
    consecutive_failures: i32,
    status: String,
    last_attempt_at: Option<chrono::DateTime<chrono::Utc>>,
    cooldown_until: Option<chrono::DateTime<chrono::Utc>>,
}

impl RestartRow {
    fn to_entry(self) -> RestartStateEntry {
        RestartStateEntry {
            pid: self.pid as u32,
            agent_name: self.agent_name,
            attempt_count: self.attempt_count as u32,
            consecutive_failures: self.consecutive_failures as u32,
            status: self.status,
            last_attempt_at: self.last_attempt_at,
            cooldown_until: self.cooldown_until,
        }
    }
}

#[derive(Debug, sqlx::FromRow)]
struct RecoveryRow {
    action_id: Uuid,
    action_type: String,
    target: String,
    expires_at: Option<chrono::DateTime<chrono::Utc>>,
    rollback_action: String,
    created_at: chrono::DateTime<chrono::Utc>,
}

impl RecoveryRow {
    fn to_entry(self) -> RecoveryActionEntry {
        RecoveryActionEntry {
            action_id: self.action_id,
            action_type: self.action_type,
            target: self.target,
            expires_at: self.expires_at,
            rollback_action: self.rollback_action,
            created_at: self.created_at,
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_enforcement_list_default_sizes() {
        let lists = EnforcementLists::default();
        assert_eq!(lists.allow_destinations.len(), 0);
        assert_eq!(lists.block_destinations.len(), 0);
    }

    #[test]
    fn test_restart_state_entry_defaults() {
        let entry = RestartStateEntry {
            pid: 1001,
            agent_name: "test-agent".to_string(),
            attempt_count: 0,
            consecutive_failures: 0,
            status: "Healthy".to_string(),
            last_attempt_at: None,
            cooldown_until: None,
        };
        assert_eq!(entry.pid, 1001);
        assert_eq!(entry.status, "Healthy");
    }
}

// ---------------------------------------------------------------------------
// Helper: notify systemd watchdog
// ---------------------------------------------------------------------------

/// Send a watchdog notification to systemd (if running under systemd).
pub fn notify_watchdog() {
    if let Ok(socket_path) = std::env::var("NOTIFY_SOCKET") {
        #[cfg(unix)]
        {
            use std::os::unix::net::UnixDatagram;
            if let Ok(sock) = UnixDatagram::unbound() {
                let _ = sock.send_to(b"WATCHDOG=1", &socket_path);
            }
        }
    }
}
