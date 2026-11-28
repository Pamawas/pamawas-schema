-- Daily freshness, failure backoff, and ownership have independent lifetimes.
ALTER TABLE telemetry_catalog_sync_state
    ADD COLUMN IF NOT EXISTS failure_count INTEGER NOT NULL DEFAULT 0 CHECK (failure_count >= 0),
    ADD COLUMN IF NOT EXISTS next_retry_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS lease_token UUID,
    ADD COLUMN IF NOT EXISTS lease_expires_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS catalog_revision_id TEXT REFERENCES telemetry_catalog_revisions(id);
