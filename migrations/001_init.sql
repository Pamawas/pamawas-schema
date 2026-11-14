-- 001_init.sql
-- Pamawas complete baseline schema.
-- Combines all incremental migrations into one authoritative init.

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS events (
    id               TEXT        PRIMARY KEY,
    source           TEXT        NOT NULL,
    source_event_id  TEXT,
    fingerprint      TEXT,
    type             TEXT        NOT NULL,
    occurred_at      TIMESTAMPTZ NOT NULL,
    received_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    service          TEXT,
    environment      TEXT        NOT NULL,
    severity         TEXT        NOT NULL
        CHECK (severity IN ('debug', 'info', 'warning', 'high', 'critical')),
    title            TEXT        NOT NULL,
    status           TEXT        NOT NULL
        CHECK (status IN ('firing', 'resolved', 'informational')),
    labels           JSONB       NOT NULL DEFAULT '{}'::jsonb,
    raw_payload      JSONB,
    schema_version   INTEGER     NOT NULL DEFAULT 1 CHECK (schema_version > 0),
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (source, source_event_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS events_source_fingerprint_occurred_at_key
    ON events (source, fingerprint, occurred_at)
    WHERE source_event_id IS NULL AND fingerprint IS NOT NULL;
CREATE INDEX IF NOT EXISTS events_occurred_at_idx    ON events (occurred_at);
CREATE INDEX IF NOT EXISTS events_service_time_idx   ON events (environment, service, occurred_at);
CREATE INDEX IF NOT EXISTS events_status_time_idx    ON events (status, occurred_at);

-- ---------------------------------------------------------------------------
-- Incidents
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS incidents (
    id                   TEXT        PRIMARY KEY,
    title                TEXT        NOT NULL,
    status               TEXT        NOT NULL
        CHECK (status IN ('open', 'investigating', 'resolved', 'suppressed')),
    started_at           TIMESTAMPTZ NOT NULL,
    last_event_at        TIMESTAMPTZ NOT NULL,
    resolved_at          TIMESTAMPTZ,
    severity             TEXT        NOT NULL
        CHECK (severity IN ('debug', 'info', 'warning', 'high', 'critical')),
    environment          TEXT        NOT NULL,
    affected_services    TEXT[]      NOT NULL DEFAULT '{}',
    correlation_policy   TEXT        NOT NULL,
    correlation_version  INTEGER     NOT NULL CHECK (correlation_version > 0),
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK ((status = 'resolved') = (resolved_at IS NOT NULL)),
    CHECK (last_event_at >= started_at)
);

CREATE TABLE IF NOT EXISTS incident_events (
    incident_id        TEXT    NOT NULL REFERENCES incidents(id) ON DELETE CASCADE,
    event_id           TEXT    NOT NULL REFERENCES events(id)    ON DELETE RESTRICT,
    correlation_reason TEXT    NOT NULL,
    policy_version     INTEGER NOT NULL CHECK (policy_version > 0),
    attached_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (incident_id, event_id),
    UNIQUE (event_id, policy_version)
);

-- ---------------------------------------------------------------------------
-- Investigation runs, tool executions & evidence
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS investigation_runs (
    id               TEXT        PRIMARY KEY,
    incident_id      TEXT        NOT NULL REFERENCES incidents(id) ON DELETE CASCADE,
    request_key_hash TEXT        NOT NULL,
    status           TEXT        NOT NULL
        CHECK (status IN (
            'queued', 'running', 'completed', 'unknown',
            'failed_retryable', 'failed_terminal'
        )),
    model_provider   TEXT        NOT NULL,
    model_name       TEXT        NOT NULL,
    prompt_version   TEXT        NOT NULL,
    tool_contract    INTEGER     NOT NULL CHECK (tool_contract > 0),
    max_tool_calls   INTEGER     NOT NULL CHECK (max_tool_calls >= 0),
    attempts         INTEGER     NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    max_attempts     INTEGER     NOT NULL DEFAULT 5 CHECK (max_attempts >= 1),
    next_retry_at    TIMESTAMPTZ,
    started_at       TIMESTAMPTZ,
    completed_at     TIMESTAMPTZ,
    safe_error_code  TEXT,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (incident_id, request_key_hash),
    CHECK (attempts <= max_attempts),
    CHECK (completed_at IS NULL OR started_at IS NULL OR completed_at >= started_at)
);

CREATE TABLE IF NOT EXISTS tool_executions (
    id                  TEXT    PRIMARY KEY,
    run_id              TEXT    NOT NULL REFERENCES investigation_runs(id) ON DELETE CASCADE,
    sequence_no         INTEGER NOT NULL CHECK (sequence_no >= 0),
    tool_name           TEXT    NOT NULL,
    arguments_redacted  JSONB   NOT NULL DEFAULT '{}'::jsonb,
    result_summary      JSONB   NOT NULL DEFAULT '{}'::jsonb,
    result_hash         TEXT,
    status              TEXT    NOT NULL,
    duration_ms         INTEGER NOT NULL CHECK (duration_ms >= 0),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (run_id, sequence_no)
);

CREATE TABLE IF NOT EXISTS evidence (
    id                   TEXT             PRIMARY KEY,
    incident_id          TEXT             NOT NULL REFERENCES incidents(id)         ON DELETE CASCADE,
    run_id               TEXT             NOT NULL REFERENCES investigation_runs(id) ON DELETE CASCADE,
    type                 TEXT             NOT NULL
        CHECK (type IN ('fact', 'likely_cause', 'hypothesis', 'unknown')),
    content              TEXT             NOT NULL,
    source               TEXT             NOT NULL,
    confidence           DOUBLE PRECISION NOT NULL CHECK (confidence >= 0.0 AND confidence <= 1.0),
    supports_evidence    TEXT[]           NOT NULL DEFAULT '{}',
    contradicts_evidence TEXT[]           NOT NULL DEFAULT '{}',
    ordinal              INTEGER          NOT NULL CHECK (ordinal >= 0),
    -- Extended data columns (metrics / logs from Prometheus & Loki)
    metrics              JSONB            DEFAULT '[]'::jsonb,
    logs                 JSONB            DEFAULT '[]'::jsonb,
    version              INTEGER          NOT NULL DEFAULT 0,
    created_at           TIMESTAMPTZ      NOT NULL DEFAULT now(),
    updated_at           TIMESTAMPTZ      DEFAULT now(),
    UNIQUE (run_id, ordinal)
);

CREATE INDEX IF NOT EXISTS idx_evidence_incident_id ON evidence (incident_id);
CREATE INDEX IF NOT EXISTS idx_evidence_version     ON evidence (id, version);

-- ---------------------------------------------------------------------------
-- Investigation outbox  (correlator → investigator delivery)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS investigation_outbox (
    id               TEXT        PRIMARY KEY,
    incident_id      TEXT        NOT NULL REFERENCES incidents(id) ON DELETE CASCADE,
    contract_version INTEGER     NOT NULL CHECK (contract_version > 0),
    request_key_hash TEXT        NOT NULL UNIQUE,
    -- reason distinguishes creation vs resolution notifications;
    -- 'incident_resolved' triggers an immediate solved-alert message.
    reason           TEXT        NOT NULL DEFAULT 'incident_created'
        CHECK (reason IN ('incident_created', 'incident_resolved')),
    status           TEXT        NOT NULL
        CHECK (status IN ('pending', 'leased', 'delivered', 'retryable', 'failed_terminal')),
    attempts         INTEGER     NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    lease_expires_at TIMESTAMPTZ,
    next_attempt_at  TIMESTAMPTZ,
    safe_error_code  TEXT,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS investigation_outbox_reason_idx
    ON investigation_outbox (reason, status);

-- ---------------------------------------------------------------------------
-- Reports & delivery
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS report_requests (
    id               TEXT        PRIMARY KEY,
    request_type     TEXT        NOT NULL CHECK (request_type IN ('daily', 'high_severity')),
    period_start     TIMESTAMPTZ NOT NULL,
    period_end       TIMESTAMPTZ NOT NULL,
    timezone         TEXT        NOT NULL,
    idempotency_hash TEXT        NOT NULL UNIQUE,
    status           TEXT        NOT NULL
        CHECK (status IN (
            'pending', 'generating', 'generated',
            'failed_retryable', 'failed_terminal'
        )),
    attempts         INTEGER     NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    next_attempt_at  TIMESTAMPTZ,
    lease_expires_at TIMESTAMPTZ,
    safe_error_code  TEXT,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (period_end > period_start)
);

CREATE TABLE IF NOT EXISTS reports (
    id               TEXT        PRIMARY KEY,
    request_id       TEXT        NOT NULL UNIQUE REFERENCES report_requests(id) ON DELETE RESTRICT,
    report_type      TEXT        NOT NULL CHECK (report_type IN ('daily', 'high_severity')),
    period_start     TIMESTAMPTZ NOT NULL,
    period_end       TIMESTAMPTZ NOT NULL,
    timezone         TEXT        NOT NULL,
    template_version TEXT        NOT NULL,
    content          TEXT        NOT NULL,
    generated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    status           TEXT        NOT NULL
        CHECK (status IN (
            'generated', 'partially_delivered', 'delivered', 'delivery_failed'
        )),
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (period_end > period_start)
);

CREATE TABLE IF NOT EXISTS report_incidents (
    report_id        TEXT NOT NULL REFERENCES reports(id)   ON DELETE CASCADE,
    incident_id      TEXT NOT NULL REFERENCES incidents(id) ON DELETE RESTRICT,
    inclusion_reason TEXT NOT NULL,
    PRIMARY KEY (report_id, incident_id)
);

CREATE TABLE IF NOT EXISTS delivery_attempts (
    id                   TEXT    PRIMARY KEY,
    report_id            TEXT    NOT NULL REFERENCES reports(id) ON DELETE CASCADE,
    channel              TEXT    NOT NULL CHECK (channel IN ('discord', 'telegram', 'email')),
    destination_key      TEXT    NOT NULL,
    status               TEXT    NOT NULL
        CHECK (status IN ('pending', 'sending', 'sent', 'retryable', 'failed_terminal')),
    attempts             INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    lease_expires_at     TIMESTAMPTZ,
    next_attempt_at      TIMESTAMPTZ,
    provider_message_id  TEXT,
    safe_error_code      TEXT,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (report_id, channel, destination_key)
);

-- ---------------------------------------------------------------------------
-- Idempotency records  (deduplication / replay protection)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS idempotency_records (
    audience          TEXT        NOT NULL,
    caller            TEXT        NOT NULL,
    key_hash          TEXT        NOT NULL,
    request_hash      TEXT        NOT NULL,
    status            TEXT        NOT NULL
        CHECK (status IN ('processing', 'completed', 'conflict')),
    result_reference  TEXT,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at        TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (audience, caller, key_hash)
);

CREATE INDEX IF NOT EXISTS idempotency_records_expires_at_idx
    ON idempotency_records (expires_at);

-- ---------------------------------------------------------------------------
-- Investigation reviews & report feedback  (quality / feedback loop)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS investigation_reviews (
    id               TEXT    PRIMARY KEY,
    incident_id      TEXT    NOT NULL REFERENCES incidents(id)         ON DELETE CASCADE,
    run_id           TEXT    NOT NULL REFERENCES investigation_runs(id) ON DELETE CASCADE,
    evidence_id      TEXT    REFERENCES evidence(id)                   ON DELETE SET NULL,
    verdict          TEXT    NOT NULL
        CHECK (verdict IN ('correct', 'incorrect', 'partially_correct', 'unknown')),
    corrected_cause  TEXT,
    notes            TEXT,
    reviewer         TEXT    NOT NULL,
    reviewed_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS investigation_reviews_incident_id_idx ON investigation_reviews (incident_id);
CREATE INDEX IF NOT EXISTS investigation_reviews_run_id_idx      ON investigation_reviews (run_id);
CREATE INDEX IF NOT EXISTS investigation_reviews_evidence_id_idx ON investigation_reviews (evidence_id);

CREATE TABLE IF NOT EXISTS report_feedback (
    id           TEXT PRIMARY KEY,
    report_id    TEXT NOT NULL REFERENCES reports(id) ON DELETE CASCADE,
    rating       TEXT NOT NULL
        CHECK (rating IN ('useful', 'not_useful', 'wrong', 'missing_context')),
    comments     TEXT,
    reviewer     TEXT NOT NULL,
    reviewed_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS report_feedback_report_id_idx ON report_feedback (report_id);
