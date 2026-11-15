-- 002_dead_letter.sql
-- Dead-letter destination for investigation outbox rows that exhausted their
-- retry budget or failed terminally. Rows are copied here (without a foreign
-- key to incidents, so they survive incident deletion) before the outbox row
-- is marked failed_terminal, giving operators a manual triage surface.

CREATE TABLE IF NOT EXISTS investigation_outbox_dead_letter (
    id               TEXT        PRIMARY KEY, -- outbox row id
    incident_id      TEXT        NOT NULL,
    contract_version INTEGER     NOT NULL CHECK (contract_version > 0),
    request_key_hash TEXT        NOT NULL,
    reason           TEXT        NOT NULL,
    attempts         INTEGER     NOT NULL CHECK (attempts >= 0),
    safe_error_code  TEXT,
    dead_lettered_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS investigation_outbox_dead_letter_time_idx
    ON investigation_outbox_dead_letter (dead_lettered_at);
