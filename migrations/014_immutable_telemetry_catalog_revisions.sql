-- 014_immutable_telemetry_catalog_revisions.sql
-- Freeze the exact provider catalog used by each full investigation. The live
-- catalog remains mutable discovery state; revisions are content-addressed,
-- append-only snapshots that retries and resumes can load verbatim.

CREATE TABLE IF NOT EXISTS telemetry_catalog_revisions (
    id            TEXT        PRIMARY KEY,
    content_hash  TEXT        NOT NULL UNIQUE,
    catalog       JSONB       NOT NULL,
    entry_count   INTEGER     NOT NULL CHECK (entry_count >= 0),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (jsonb_typeof(catalog) = 'object')
);

ALTER TABLE investigation_runs
    ADD COLUMN IF NOT EXISTS catalog_revision_id TEXT;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'investigation_runs_catalog_revision_id_fkey'
    ) THEN
        ALTER TABLE investigation_runs
            ADD CONSTRAINT investigation_runs_catalog_revision_id_fkey
            FOREIGN KEY (catalog_revision_id)
            REFERENCES telemetry_catalog_revisions(id)
            ON DELETE RESTRICT;
    END IF;
END
$$;

CREATE INDEX IF NOT EXISTS investigation_runs_catalog_revision_id_idx
    ON investigation_runs (catalog_revision_id)
    WHERE catalog_revision_id IS NOT NULL;

-- Historical runs stay NULL because their exact catalog cannot be
-- reconstructed honestly. New full investigations pin a revision before the
-- first model turn. A database guard makes a pinned run immutable as well as
-- making revision content append-only.
CREATE OR REPLACE FUNCTION reject_telemetry_catalog_revision_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'telemetry catalog revisions are immutable';
END;
$$;

DROP TRIGGER IF EXISTS telemetry_catalog_revisions_immutable
    ON telemetry_catalog_revisions;

CREATE TRIGGER telemetry_catalog_revisions_immutable
BEFORE UPDATE OR DELETE ON telemetry_catalog_revisions
FOR EACH ROW
EXECUTE FUNCTION reject_telemetry_catalog_revision_mutation();

CREATE OR REPLACE FUNCTION reject_investigation_catalog_repin()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.catalog_revision_id IS NOT NULL
       AND NEW.catalog_revision_id IS DISTINCT FROM OLD.catalog_revision_id THEN
        RAISE EXCEPTION 'an investigation catalog revision cannot be changed';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS investigation_runs_catalog_revision_immutable
    ON investigation_runs;

CREATE TRIGGER investigation_runs_catalog_revision_immutable
BEFORE UPDATE OF catalog_revision_id ON investigation_runs
FOR EACH ROW
EXECUTE FUNCTION reject_investigation_catalog_repin();
