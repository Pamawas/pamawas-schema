-- 003_incident_alert_tracking.sql
-- Per-incident alert tracking. The immediate high-severity alert is now
-- event-driven: ingest forwards a firing event to the reporter, which claims
-- the one-shot alert per incident with an atomic UPDATE ... WHERE
-- alert_notified_at IS NULL. Grafana re-fires the same alert every evaluation
-- interval, so the claim is what keeps a sustained incident from buzzing
-- every 30-60 seconds; a resolved-then-refired incident correlates to a NEW
-- incident row (resolved incidents are not correlation candidates), so it
-- alerts again on its own.

ALTER TABLE incidents
    ADD COLUMN IF NOT EXISTS alert_notified_at TIMESTAMPTZ;