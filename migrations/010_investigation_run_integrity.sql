-- 010_investigation_run_integrity.sql
-- Give every investigation run an explicit purpose and pin each report/incident
-- snapshot to the exact full-investigation run whose evidence it rendered.

ALTER TABLE investigation_runs
    ADD COLUMN IF NOT EXISTS run_kind TEXT;

UPDATE investigation_runs
SET run_kind = CASE
    WHEN request_key_hash LIKE 'verification:%' THEN 'verification'
    ELSE 'investigation'
END
WHERE run_kind IS NULL;

ALTER TABLE investigation_runs
    ALTER COLUMN run_kind SET DEFAULT 'investigation',
    ALTER COLUMN run_kind SET NOT NULL;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'investigation_runs_run_kind_check'
    ) THEN
        ALTER TABLE investigation_runs
            ADD CONSTRAINT investigation_runs_run_kind_check
            CHECK (run_kind IN ('investigation', 'verification'));
    END IF;
END
$$;

CREATE INDEX IF NOT EXISTS idx_investigation_runs_latest_full
    ON investigation_runs (incident_id, completed_at DESC, created_at DESC)
    WHERE run_kind = 'investigation' AND status = 'completed';

ALTER TABLE report_incidents
    ADD COLUMN IF NOT EXISTS run_id TEXT;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'report_incidents_run_id_fkey'
    ) THEN
        ALTER TABLE report_incidents
            ADD CONSTRAINT report_incidents_run_id_fkey
            FOREIGN KEY (run_id) REFERENCES investigation_runs(id) ON DELETE SET NULL;
    END IF;
END
$$;

-- Historical report content is immutable. Record the best matching full run
-- for audit without rewriting any rendered report body. Build the correlation
-- in a CTE: PostgreSQL does not allow the UPDATE target alias to be referenced
-- from every form of LATERAL subquery in the FROM clause.
WITH historical_selection AS (
    SELECT
        ri.report_id,
        ri.incident_id,
        (
            SELECT ir.id
            FROM investigation_runs ir
            WHERE ir.incident_id = ri.incident_id
              AND ir.run_kind = 'investigation'
              AND ir.status = 'completed'
              AND ir.completed_at <= r.generated_at
            ORDER BY ir.completed_at DESC, ir.created_at DESC
            LIMIT 1
        ) AS run_id
    FROM report_incidents ri
    JOIN reports r ON r.id = ri.report_id
    WHERE ri.run_id IS NULL
)
UPDATE report_incidents ri
SET run_id = selected.run_id
FROM historical_selection selected
WHERE ri.report_id = selected.report_id
  AND ri.incident_id = selected.incident_id
  AND selected.run_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_report_incidents_run_id
    ON report_incidents (run_id);
