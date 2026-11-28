-- Reviewed operational actions change independently of telemetry discovery.
CREATE TABLE IF NOT EXISTS investigation_policies (
    id                    TEXT        NOT NULL CHECK (char_length(id) BETWEEN 1 AND 128),
    version               INTEGER     NOT NULL CHECK (version > 0),
    enabled               BOOLEAN     NOT NULL DEFAULT false,
    priority              INTEGER     NOT NULL DEFAULT 0,
    labels                JSONB       NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(labels) = 'object'),
    provider              TEXT        NOT NULL CHECK (provider IN ('prometheus', 'loki')),
    metric_type           TEXT,
    metric_unit           TEXT,
    minimum_observations  INTEGER     NOT NULL DEFAULT 1 CHECK (minimum_observations > 0),
    recommendation        TEXT        NOT NULL CHECK (char_length(btrim(recommendation)) BETWEEN 1 AND 1500),
    runbook_reference     TEXT        CHECK (char_length(btrim(runbook_reference)) BETWEEN 1 AND 500),
    approved_by           TEXT        NOT NULL CHECK (char_length(btrim(approved_by)) > 0),
    approved_at           TIMESTAMPTZ NOT NULL,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (id, version),
    CHECK (provider = 'prometheus' OR (metric_type IS NULL AND metric_unit IS NULL))
);

ALTER TABLE investigation_runs
    ADD COLUMN IF NOT EXISTS recommendation_policy_id TEXT,
    ADD COLUMN IF NOT EXISTS recommendation_policy_version INTEGER,
    ADD CONSTRAINT investigation_runs_recommendation_policy_fkey
        FOREIGN KEY (recommendation_policy_id, recommendation_policy_version)
        REFERENCES investigation_policies (id, version) MATCH FULL;

CREATE OR REPLACE FUNCTION protect_investigation_policy_version()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'investigation policy versions are retained';
    END IF;
    IF (to_jsonb(OLD) - 'enabled') IS DISTINCT FROM (to_jsonb(NEW) - 'enabled') THEN
        RAISE EXCEPTION 'publish a new investigation policy version to change its content';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER investigation_policies_version_immutable
BEFORE UPDATE OR DELETE ON investigation_policies
FOR EACH ROW EXECUTE FUNCTION protect_investigation_policy_version();
