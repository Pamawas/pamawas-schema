-- 011_alert_evidence_source.sql
-- Alert payload observations are first-class evidence produced by the
-- investigator. Keep the database's closed source set aligned with the
-- EvidenceSource enum before those findings are persisted.

ALTER TABLE evidence
    DROP CONSTRAINT IF EXISTS evidence_source_check;

ALTER TABLE evidence
    ADD CONSTRAINT evidence_source_check
    CHECK (source IN ('prometheus', 'loki', 'alert', 'incidents', 'llm', 'system'));
