-- Store selection decisions and prompt sizes without retaining model input.
ALTER TABLE investigation_runs
    ADD COLUMN IF NOT EXISTS prompt_context_audit JSONB
    CHECK (prompt_context_audit IS NULL OR jsonb_typeof(prompt_context_audit) = 'object');
