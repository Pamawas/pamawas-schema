-- 003_evidence_source_and_recommendation.sql
-- Two related changes to how evidence describes itself:
--
-- 1. `source` becomes a closed set. It was free text, which produced dozens of
--    one-off strings ('Prometheus up metric', 'Loki logs query', ...) that
--    could not be aggregated and could not answer the one question a reader
--    asks: did this come from metrics or logs? Existing rows are mapped onto
--    the closed set before the constraint is added.
-- 2. `recommendation` joins the evidence types. A recommended operator action
--    is not a claim about the incident, so it must not be filed as a fact.
--
-- source_detail records what was actually asked (the query, stream, or metric),
-- because the source alone says which system answered, not what it was told.

ALTER TABLE evidence
    ADD COLUMN IF NOT EXISTS source_detail TEXT NOT NULL DEFAULT '';

-- Map the old free text onto the closed set. Order matters: a finding that
-- cites both metrics and logs is the model's synthesis across them, not an
-- observation from either one, so it is classified first.
UPDATE evidence
   SET source = 'llm'
 WHERE source ILIKE '%prometheus%' AND source ILIKE '%loki%';

UPDATE evidence
   SET source = 'prometheus'
 WHERE source ILIKE '%prometheus%';

UPDATE evidence
   SET source = 'loki'
 WHERE source ILIKE '%loki%';

UPDATE evidence
   SET source = 'system'
 WHERE source IN ('investigator_error', 'investigator_timeout');

UPDATE evidence
   SET source = 'incidents'
 WHERE source ILIKE '%incident%';

-- Anything still outside the closed set described the model's own reasoning
-- (correlations, inferences, 'insufficient evidence').
UPDATE evidence
   SET source = 'llm'
 WHERE source NOT IN ('prometheus', 'loki', 'incidents', 'system', 'llm');

ALTER TABLE evidence
    DROP CONSTRAINT IF EXISTS evidence_source_check;

ALTER TABLE evidence
    ADD CONSTRAINT evidence_source_check
    CHECK (source IN ('prometheus', 'loki', 'incidents', 'llm', 'system'));

ALTER TABLE evidence
    DROP CONSTRAINT IF EXISTS evidence_type_check;

ALTER TABLE evidence
    ADD CONSTRAINT evidence_type_check
    CHECK (type IN ('fact', 'likely_cause', 'hypothesis', 'unknown', 'recommendation'));
