-- 007_report_request_incident.sql
-- A high-severity report request is about one incident; say so in a column.
--
-- The incident used to be encoded in the idempotency hash as a "|incidentID"
-- suffix, and the follow-up sweep parsed it back out with LastIndex. That made
-- the hash carry two unrelated jobs, and it tied the sweep to the hash format.
-- The column also lets the scheduler ask "does this incident already have a
-- report?" directly, which is the question the idempotency key was standing in
-- for.

ALTER TABLE report_requests ADD COLUMN IF NOT EXISTS incident_id TEXT
    REFERENCES incidents(id) ON DELETE CASCADE;

-- Backfill from the suffix while the old format is still in the table.
UPDATE report_requests
SET incident_id = substring(idempotency_hash from '[^|]+$')
WHERE request_type = 'high_severity'
  AND idempotency_hash LIKE '%|%'
  AND incident_id IS NULL
  AND EXISTS (
      SELECT 1 FROM incidents i
      WHERE i.id = substring(report_requests.idempotency_hash from '[^|]+$')
  );

CREATE INDEX IF NOT EXISTS report_requests_incident_id_idx
    ON report_requests (incident_id)
    WHERE incident_id IS NOT NULL;
