-- 012_live_telemetry_catalog.sql
-- Provider schemas change independently of Pamawas releases. Persist the live
-- Prometheus metric metadata and Loki label schema so each investigation can
-- score evidence against one deterministic catalog snapshot while a bounded
-- refresh keeps later runs current.

CREATE TABLE IF NOT EXISTS telemetry_catalog_entries (
    provider       TEXT        NOT NULL CHECK (provider IN ('prometheus', 'loki')),
    resource_kind  TEXT        NOT NULL CHECK (resource_kind IN ('metric', 'label')),
    resource_name  TEXT        NOT NULL,
    search_text    TEXT        NOT NULL DEFAULT '',
    metadata       JSONB       NOT NULL DEFAULT '{}'::jsonb,
    first_seen_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (provider, resource_kind, resource_name)
);

CREATE INDEX IF NOT EXISTS telemetry_catalog_entries_last_seen_idx
    ON telemetry_catalog_entries (provider, last_seen_at DESC);

CREATE TABLE IF NOT EXISTS telemetry_catalog_sync_state (
    provider          TEXT PRIMARY KEY CHECK (provider IN ('prometheus', 'loki')),
    last_attempted_at TIMESTAMPTZ,
    last_succeeded_at TIMESTAMPTZ,
    last_error_class  TEXT,
    entry_count       INTEGER NOT NULL DEFAULT 0 CHECK (entry_count >= 0),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
