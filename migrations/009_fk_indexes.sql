-- Migration: 009_fk_indexes.sql
-- Add missing foreign key indexes to prevent table scans on referenced table deletions and updates.

CREATE INDEX IF NOT EXISTS idx_investigation_outbox_incident_id
    ON investigation_outbox (incident_id);

CREATE INDEX IF NOT EXISTS idx_correlation_decisions_incident_id
    ON correlation_decisions (incident_id);

CREATE INDEX IF NOT EXISTS idx_stale_verifications_run_id
    ON stale_verifications (run_id);
