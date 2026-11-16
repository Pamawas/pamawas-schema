-- 005_correlation_decisions.sql
-- Give every incident a stable identity, and record what the correlator did
-- with every event — including the events that produce no incident.
--
-- Two defects drove this migration.
--
-- 1. `incident_events` was doing double duty: it was both the incident↔event
--    link and the "this event has been processed" marker. Because incident_id
--    is NOT NULL, an event with nothing to attach to had no way to be marked
--    seen — so a `resolved` event arriving with no open incident created a
--    brand-new *open* incident. Those incidents claim a condition is broken
--    when the event says it recovered, and nothing ever resolves them.
--
-- 2. Incidents had no identity. Matching was a fuzzy score over service,
--    title and labels, and every attached event overwrote `title` and
--    `affected_services`. A koba-labs "RAM" incident could absorb a last-labs
--    "Monitoring Target Down" firing and become a "Monitoring Target Down"
--    incident with `affected_services = {last-labs}` — a rolling bucket of
--    whatever happened to be in production within 15 minutes.
--
-- Grafana already sends the answer: `alerts[0].fingerprint` is a stable hash
-- of the alert's label set, stored in `events.labels->>'grafana_fingerprint'`
-- on 100% of current events. Two alerts that share a service and title but
-- differ in `job` (koba-labs MTD on docker_cadvisor vs mariadb) have different
-- fingerprints, and the same alert's firing and resolved events share one.
-- Identity is exact, not scored.

-- ---------------------------------------------------------------------------
-- 1. The processing record, separate from the incident link.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS correlation_decisions (
    event_id       TEXT        NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    policy_version INTEGER     NOT NULL CHECK (policy_version > 0),
    decision       TEXT        NOT NULL
        CHECK (decision IN ('new_incident', 'extended_incident', 'resolved_incident', 'ignored')),
    incident_id    TEXT        REFERENCES incidents(id) ON DELETE CASCADE,
    decided_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (event_id, policy_version),
    -- A decision that produced an incident must name it; an ignored event must not.
    CONSTRAINT correlation_decisions_incident_required
        CHECK ((decision = 'ignored') = (incident_id IS NULL))
);

CREATE INDEX IF NOT EXISTS correlation_decisions_decided_at_idx
    ON correlation_decisions (decided_at);

-- ---------------------------------------------------------------------------
-- 2. Repair existing incidents.
-- ---------------------------------------------------------------------------

-- An incident is open only while its condition is firing. If the newest event
-- attached to it is a resolution, the incident is over — it was left open
-- because a later unrelated event kept extending it, or because it was born
-- from the resolution in the first place.
WITH latest AS (
    SELECT DISTINCT ON (ie.incident_id)
           ie.incident_id, e.status, e.occurred_at
    FROM incident_events ie
    JOIN events e ON e.id = ie.event_id
    ORDER BY ie.incident_id, e.occurred_at DESC, e.id DESC
)
UPDATE incidents i
SET status      = 'resolved',
    resolved_at = GREATEST(l.occurred_at, i.started_at),
    updated_at  = now()
FROM latest l
WHERE l.incident_id = i.id
  AND i.status IN ('open', 'investigating')
  AND l.status <> 'firing';

-- Titles and affected services were overwritten by every attached event, so
-- they can describe an event that has nothing to do with the incident. They are
-- restored together with the identity below, from the event that created the
-- incident.

-- ---------------------------------------------------------------------------
-- 3. Stable identity.
-- ---------------------------------------------------------------------------
ALTER TABLE incidents ADD COLUMN IF NOT EXISTS identity_key TEXT;

-- The earliest attached event is the one that created the incident, so it
-- defines what the incident is: its condition, its title, and the service that
-- alerted. All three are rewritten from that single row so they cannot
-- disagree with each other.
--
-- The two branches mirror eventIdentity() in the correlator:
--   'fp:<grafana fingerprint>'  when the source supplies one
--   'cond:<service>|<title>'    otherwise, lowercased and trimmed
-- Both sides must agree or new events will not find the incidents this
-- migration repaired.
WITH origin AS (
    SELECT DISTINCT ON (ie.incident_id)
           ie.incident_id,
           COALESCE(e.labels->>'grafana_fingerprint', '') AS fingerprint,
           COALESCE(e.service, '') AS service,
           e.title
    FROM incident_events ie
    JOIN events e ON e.id = ie.event_id
    ORDER BY ie.incident_id, e.occurred_at ASC, e.id ASC
)
UPDATE incidents i
SET identity_key = CASE
        WHEN origin.fingerprint <> '' THEN 'fp:' || origin.fingerprint
        ELSE 'cond:' || lower(trim(origin.service)) || '|' || lower(trim(origin.title))
    END,
    title = origin.title,
    affected_services = CASE
        WHEN origin.service <> '' THEN ARRAY[origin.service]
        ELSE ARRAY[]::text[]
    END
FROM origin
WHERE origin.incident_id = i.id;

-- Incidents with no events at all (never correlated, only referenced by a
-- report) keep an identity that cannot collide with a real condition.
UPDATE incidents SET identity_key = 'legacy:' || id WHERE identity_key IS NULL;

-- Two open incidents for one identity means the old matcher failed to find the
-- one it had already created. Keep the most recently active and close the rest
-- at their last event, so history stays intact and the digest stops listing
-- the same condition twice.
WITH ranked AS (
    SELECT i.id,
           ROW_NUMBER() OVER (
               PARTITION BY i.environment, i.identity_key
               ORDER BY i.last_event_at DESC, i.started_at DESC, i.id DESC
           ) AS rn
    FROM incidents i
    WHERE i.status IN ('open', 'investigating')
)
UPDATE incidents i
SET status      = 'resolved',
    resolved_at = i.last_event_at,
    updated_at  = now()
FROM ranked r
WHERE r.id = i.id AND r.rn > 1;

ALTER TABLE incidents ALTER COLUMN identity_key SET NOT NULL;

-- At most one open incident per condition, enforced by the database rather
-- than by the correlator remembering to look first.
CREATE UNIQUE INDEX IF NOT EXISTS incidents_open_identity_key_idx
    ON incidents (environment, identity_key)
    WHERE status IN ('open', 'investigating');

-- ---------------------------------------------------------------------------
-- 4. Mark already-correlated events as processed.
-- ---------------------------------------------------------------------------
INSERT INTO correlation_decisions (event_id, policy_version, decision, incident_id, decided_at)
SELECT
    ie.event_id,
    ie.policy_version,
    CASE ie.correlation_reason
        WHEN 'new_incident' THEN 'new_incident'
        WHEN 'resolution_of_open_incident' THEN 'resolved_incident'
        ELSE 'extended_incident'
    END,
    ie.incident_id,
    ie.attached_at
FROM incident_events ie
ON CONFLICT (event_id, policy_version) DO NOTHING;
