-- 013_event_condition_reference.sql
-- Persist the alert source's stable condition identity separately from its raw
-- webhook payload. Recovery evaluators use this reference to ask the source
-- for the exact current rule/instance state; telemetry and free-form alert
-- text are never allowed to define recovery.

ALTER TABLE events
    ADD COLUMN IF NOT EXISTS condition_ref JSONB;

ALTER TABLE events
    DROP CONSTRAINT IF EXISTS events_condition_ref_object_check;

ALTER TABLE events
    ADD CONSTRAINT events_condition_ref_object_check
    CHECK (condition_ref IS NULL OR jsonb_typeof(condition_ref) = 'object');

-- Backfill legacy Grafana events from source-owned identity fields already
-- retained in raw_payload. The normalized event fingerprint chooses the exact
-- alert represented by the event, including when Grafana delivered a grouped
-- notification. Ambiguous matches and payloads without a rule UID remain NULL
-- and therefore fail closed during recovery evaluation.
WITH grafana_candidates AS (
    SELECT
        e.id AS event_id,
        candidate.alert,
        e.raw_payload,
        count(*) OVER (PARTITION BY e.id) AS candidate_count
    FROM events e
    CROSS JOIN LATERAL (
        SELECT CASE
            WHEN jsonb_typeof(e.raw_payload->'alerts') = 'array'
                THEN e.raw_payload->'alerts'
            ELSE '[]'::jsonb
        END AS alerts
    ) normalized
    CROSS JOIN LATERAL (
        SELECT value AS alert
        FROM jsonb_array_elements(normalized.alerts)
        UNION ALL
        SELECT e.raw_payload
        WHERE jsonb_array_length(normalized.alerts) = 0
    ) candidate
    WHERE e.source = 'grafana'
      AND e.condition_ref IS NULL
      AND jsonb_typeof(e.raw_payload) = 'object'
      AND jsonb_typeof(candidate.alert) = 'object'
      AND nullif(btrim(e.labels->>'grafana_fingerprint'), '') IS NOT NULL
      AND candidate.alert->>'fingerprint' = e.labels->>'grafana_fingerprint'
),
grafana_condition_refs AS (
    SELECT
        event_id,
        jsonb_build_object(
            'version', 1,
            'source', 'grafana',
            'evaluator', 'managed_alerting',
            'resource_type', 'alert_rule',
            'resource_id', coalesce(
                nullif(btrim(alert->>'ruleUID'), ''),
                nullif(btrim(alert->>'ruleUid'), ''),
                nullif(btrim(alert->'labels'->>'__alert_rule_uid__'), '')
            ),
            'instance_id', btrim(alert->>'fingerprint'),
            'tenant_id', coalesce(
                nullif(btrim(alert->>'orgId'), ''),
                nullif(btrim(raw_payload->>'orgId'), '')
            ),
            'labels', CASE
                WHEN jsonb_typeof(alert->'labels') = 'object' THEN alert->'labels'
                ELSE '{}'::jsonb
            END
        ) AS condition_ref
    FROM grafana_candidates
    WHERE candidate_count = 1
      AND coalesce(
            nullif(btrim(alert->>'ruleUID'), ''),
            nullif(btrim(alert->>'ruleUid'), ''),
            nullif(btrim(alert->'labels'->>'__alert_rule_uid__'), '')
          ) IS NOT NULL
      AND char_length(coalesce(
            nullif(btrim(alert->>'ruleUID'), ''),
            nullif(btrim(alert->>'ruleUid'), ''),
            nullif(btrim(alert->'labels'->>'__alert_rule_uid__'), '')
          )) <= 256
      AND char_length(btrim(alert->>'fingerprint')) BETWEEN 1 AND 256
      AND coalesce(
            nullif(btrim(alert->>'orgId'), ''),
            nullif(btrim(raw_payload->>'orgId'), '')
          ) ~ '^[1-9][0-9]*$'
      AND char_length(coalesce(
            nullif(btrim(alert->>'orgId'), ''),
            nullif(btrim(raw_payload->>'orgId'), '')
          )) <= 128
)
UPDATE events e
SET condition_ref = refs.condition_ref
FROM grafana_condition_refs refs
WHERE e.id = refs.event_id
  AND e.condition_ref IS NULL;
