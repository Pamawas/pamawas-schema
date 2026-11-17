-- Migration: 008_stale_verifications.sql
-- Dedicated verification tracking and anti-flood back-off for stale incidents.

CREATE TABLE IF NOT EXISTS stale_verifications (
    incident_id      TEXT        PRIMARY KEY REFERENCES incidents(id) ON DELETE CASCADE,
    status           TEXT        NOT NULL
        CHECK (status IN ('queued', 'running', 'completed', 'failed')),
    verdict          TEXT
        CHECK (verdict IS NULL OR verdict IN ('recovered', 'still_down', 'inconclusive')),
    reason           TEXT,
    run_id           TEXT        REFERENCES investigation_runs(id) ON DELETE SET NULL,
    attempts         INTEGER     NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    max_attempts     INTEGER     NOT NULL DEFAULT 3 CHECK (max_attempts >= 1),
    lease_expires_at TIMESTAMPTZ,
    verified_at      TIMESTAMPTZ,
    next_verify_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    reported_at      TIMESTAMPTZ,
    safe_error_code  TEXT,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_stale_verifications_status_next
    ON stale_verifications (status, next_verify_at);

CREATE INDEX IF NOT EXISTS idx_stale_verifications_unreported
    ON stale_verifications (status, reported_at)
    WHERE status = 'completed' AND reported_at IS NULL;
