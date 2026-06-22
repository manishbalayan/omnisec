-- Migration 007: Convert event_type and severity columns from ENUM to plain TEXT
--
-- Rationale: The daemon stores NATS-subject-derived strings as event types
-- (e.g. 'agent_discovered', 'security_anomaly_detected'). A rigid ENUM
-- requires keeping every NATS subject in sync with the DB type definition,
-- which is fragile. Plain TEXT accepts any event string without migration churn.
--
-- Safe on:
--   - Fresh deploys          : ENUM columns → TEXT, ENUM types dropped
--   - Ubuntu VM / runtime fix: columns already TEXT, interim DOMAINs dropped

-- Step 1: Convert columns to TEXT (USING clause handles ENUM→TEXT and domain→TEXT)
ALTER TABLE events ALTER COLUMN event_type TYPE TEXT USING event_type::TEXT;
ALTER TABLE events ALTER COLUMN severity    TYPE TEXT USING severity::TEXT;

-- Step 2: Drop the ENUM or interim DOMAIN for event_type (whichever is present)
DO $$
DECLARE v char;
BEGIN
    SELECT typtype INTO v
      FROM pg_type t
      JOIN pg_namespace n ON n.oid = t.typnamespace
     WHERE t.typname = 'event_type' AND n.nspname = 'public';
    IF v = 'e' THEN EXECUTE 'DROP TYPE event_type CASCADE';
    ELSIF v = 'd' THEN EXECUTE 'DROP DOMAIN event_type CASCADE';
    END IF;
END $$;

-- Step 3: Drop the ENUM or interim DOMAIN for event_severity
DO $$
DECLARE v char;
BEGIN
    SELECT typtype INTO v
      FROM pg_type t
      JOIN pg_namespace n ON n.oid = t.typnamespace
     WHERE t.typname = 'event_severity' AND n.nspname = 'public';
    IF v = 'e' THEN EXECUTE 'DROP TYPE event_severity CASCADE';
    ELSIF v = 'd' THEN EXECUTE 'DROP DOMAIN event_severity CASCADE';
    END IF;
END $$;
