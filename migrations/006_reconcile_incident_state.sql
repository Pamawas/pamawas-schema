-- 006_reconcile_incident_state.sql
-- Close incidents whose condition is no longer firing, judged from the event
-- stream rather than from the incident's own event links.
--
-- 005 closed incidents whose newest *attached* event was a resolution. That
-- rule missed the worst cases: the old matcher attached resolving events to a
-- different incident than the one they resolved, so an incident could be left
-- open with only firing events attached while the condition's resolution sat
-- on someone else's incident.
--
-- The five incidents that survived 005 in production were all of this kind:
-- their fingerprints had resolved hours earlier, but those resolutions were
-- recorded against other incidents. The daily digest therefore still showed
-- conditions as open that had recovered.
--
-- The event stream is the truth. Group it by the same identity the correlator
-- computes (eventIdentity), take the newest event for each, and close anything
-- still open whose newest event is not firing.

UPDATE incidents i
SET status      = 'resolved',
    resolved_at = GREATEST(cond.latest_at, i.started_at),
    updated_at  = now()
FROM (
    SELECT DISTINCT ON (environment, identity_key)
           environment,
           identity_key,
           status,
           occurred_at AS latest_at
    FROM (
        SELECT e.environment,
               CASE
                   WHEN COALESCE(e.labels->>'grafana_fingerprint', '') <> ''
                       THEN 'fp:' || (e.labels->>'grafana_fingerprint')
                   ELSE 'cond:' || lower(trim(COALESCE(e.service, ''))) || '|' || lower(trim(e.title))
               END AS identity_key,
               e.status,
               e.occurred_at
        FROM events e
    ) AS events_by_identity
    ORDER BY environment, identity_key, occurred_at DESC
) AS cond
WHERE cond.environment = i.environment
  AND cond.identity_key = i.identity_key
  AND i.status IN ('open', 'investigating')
  AND cond.status <> 'firing';
