-- | Add metrics and logs columns to evidence table as JSONB
-- This migration extends the evidence table to store Prometheus metrics
-- and Loki logs directly in the JSONB data field.
-- Per system design: evidence.data.metrics and evidence.data.logs extensions.

-- Add version column for optimistic concurrency control
ALTER TABLE evidence ADD COLUMN IF NOT EXISTS version INTEGER NOT NULL DEFAULT 0;

-- Add metrics JSONB column
ALTER TABLE evidence ADD COLUMN IF NOT EXISTS metrics JSONB DEFAULT '[]'::jsonb;

-- Add logs JSONB column
ALTER TABLE evidence ADD COLUMN IF NOT EXISTS logs JSONB DEFAULT '[]'::jsonb;

-- Add updated_at column if not exists
ALTER TABLE evidence ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT now();

-- Create index on incident_id for faster lookups
CREATE INDEX IF NOT EXISTS idx_evidence_incident_id ON evidence(incident_id);

-- Create index on version for concurrency checks (partial index)
CREATE INDEX IF NOT EXISTS idx_evidence_version ON evidence(id, version);

COMMIT;