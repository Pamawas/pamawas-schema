-- 004_incident_identity_indexes.sql
-- The reporter resolves an alert's identity from the event alone: at fire time
-- there is no incident id, so it matches on environment + affected entity +
-- alert name. It uses that for two things now — linking a recovered alert to its
-- incident, and counting how often the condition has recurred.
--
-- Without these indexes both lookups are sequential scans. `incidents` had only
-- a primary key, so $2 = ANY(affected_services) could not use an index at all.

-- Supports "recent incidents for this environment and alert name", which is the
-- recurrence count and the incident link.
CREATE INDEX IF NOT EXISTS incidents_env_title_started_idx
    ON incidents (environment, title, started_at DESC);

-- Supports membership tests on the affected-entity array. A btree cannot
-- accelerate ANY(array); GIN can.
CREATE INDEX IF NOT EXISTS incidents_affected_services_gin
    ON incidents USING GIN (affected_services);
