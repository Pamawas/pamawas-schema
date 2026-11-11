-- 005_resolve_notification.sql
-- Add a `reason` column to investigation_outbox so the outbox worker can
-- distinguish incident creation notifications from incident resolution
-- notifications. Resolution notifications ("incident_resolved") trigger an
-- immediate user-facing alert-solved message via Discord/Telegram/Email for
-- high/critical severity alerts only.

ALTER TABLE investigation_outbox
    ADD COLUMN IF NOT EXISTS reason TEXT NOT NULL DEFAULT 'incident_created'
        CHECK (reason IN ('incident_created', 'incident_resolved'));

-- Index the reason column so the outbox worker can filter by reason efficiently.
CREATE INDEX IF NOT EXISTS investigation_outbox_reason_idx
    ON investigation_outbox (reason, status);

INSERT INTO schema_migrations (version, applied_at)
VALUES ('005', now())
ON CONFLICT (version) DO NOTHING;
