# pamawas-schema

**Shared Database Schema & Migrations** — PostgreSQL tables for all Pamawas components

Language: Go (for migration tooling) / SQL

## Purpose

Provides the canonical database schema shared by all Pamawas components. Contains all table definitions, migrations, and shared Go types. This is the single source of truth for the data model.

## MVP Reference

- **MVP §5 Data Model (PostgreSQL)**: events, incidents, incident_events, evidence, reports tables
- **MVP §5 Common Event Schema**: Normalized event structure
- **All components depend on this**: ingest, correlator, investigator, reporter, scheduler

## Tables

### events

Raw normalized events from all ingestion sources.

```sql
CREATE TABLE IF NOT EXISTS events (
    id TEXT PRIMARY KEY,
    source TEXT NOT NULL,           -- grafana, prometheus, loki, generic
    type TEXT NOT NULL,             -- alert, event, metric
    timestamp TIMESTAMPTZ NOT NULL, -- ISO8601 timestamp
    service TEXT,                   -- service name (e.g., payment-api)
    environment TEXT,               -- environment (e.g., production)
    severity TEXT,                  -- critical, high, warning, info, debug
    title TEXT,                     -- human-readable title
    status TEXT,                    -- firing, resolved
    labels JSONB,                   -- key-value labels from source
    raw_payload JSONB               -- original webhook payload for debugging
);
```

### incidents

Correlated groups of events representing a single infrastructure incident.

```sql
CREATE TABLE IF NOT EXISTS incidents (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,            -- incident title
    status TEXT NOT NULL,           -- firing, resolved
    started_at TIMESTAMPTZ,         -- first event timestamp
    resolved_at TIMESTAMPTZ,        -- last event timestamp (if resolved)
    severity TEXT,                  -- highest severity in group
    affected_services TEXT[]        -- unique services affected
);
```

### incident_events

Many-to-many link between incidents and events.

```sql
CREATE TABLE IF NOT EXISTS incident_events (
    incident_id TEXT NOT NULL REFERENCES incidents(id) ON DELETE CASCADE,
    event_id TEXT NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    PRIMARY KEY (incident_id, event_id)
);
```

### evidence

Investigation findings from the LLM investigator with evidence classification.

```sql
CREATE TABLE IF NOT EXISTS evidence (
    id TEXT PRIMARY KEY,
    incident_id TEXT NOT NULL REFERENCES incidents(id) ON DELETE CASCADE,
    type TEXT NOT NULL CHECK (type IN ('fact', 'likely_cause', 'hypothesis', 'unknown')),
    content TEXT NOT NULL,          -- finding description
    source TEXT,                    -- source: prometheus, loki, deployments, investigator
    confidence DOUBLE PRECISION CHECK (confidence >= 0.0 AND confidence <= 1.0)
);
```

### reports

Generated and delivered reports.

```sql
CREATE TABLE IF NOT EXISTS reports (
    id TEXT PRIMARY KEY,
    incident_id TEXT NOT NULL REFERENCES incidents(id) ON DELETE CASCADE,
    content TEXT NOT NULL,          -- rendered report content
    sent_at TIMESTAMPTZ,            -- when report was sent
    channels TEXT[]                 -- which channels: discord, telegram, email
);
```

## Migrations

Located in `migrations/` directory:

| File | Description |
|------|-------------|
| `001_init.sql` | Initial schema with all 5 tables |

## Shared Go Types (main.go)

```go
// Event represents the normalized event from the database
type Event struct {
    ID           string            `json:"id"`
    Source       string            `json:"source"`
    Type         string            `json:"type"`
    Timestamp    time.Time         `json:"timestamp"`
    Service      string            `json:"service,omitempty"`
    Environment  string            `json:"environment,omitempty"`
    Severity     string            `json:"severity,omitempty"`
    Title        string            `json:"title,omitempty"`
    Status       string            `json:"status,omitempty"`
    Labels       map[string]string `json:"labels,omitempty"`
}

// Incident represents a correlated group of events
type Incident struct {
    ID               string   `json:"id"`
    Title            string   `json:"title"`
    Status           string   `json:"status"`
    StartedAt        time.Time `json:"started_at"`
    ResolvedAt       time.Time `json:"resolved_at,omitempty"`
    Severity         string   `json:"severity,omitempty"`
    AffectedServices []string `json:"affected_services"`
    EventIDs         []string `json:"event_ids"`
}
```

## Usage by Components

| Component | Reads | Writes |
|-----------|-------|--------|
| pamawas-ingest | — | events |
| pamawas-correlator | events | incidents, incident_events |
| pamawas-investigator | incidents, events | evidence |
| pamawas-reporter | incidents, evidence | reports |
| pamawas-scheduler | incidents | — |

## Current Implementation Status

- ✅ Complete SQL schema with all 5 tables + schema_migrations table
- ✅ Migration file (001_init.sql) with proper indexes and constraints
- ✅ Shared Go types in main.go
- ✅ **Migration runner service (main.go)** — auto-applies migrations on startup, idempotent, version tracking, health endpoint
- ✅ Multi-stage Dockerfile for migration runner
- ✅ Embedded migrations support (USE_EMBEDDED_MIGRATIONS=true)
- ✅ GitHub Actions workflow (main + dev branches, GHCR publishing)
- ✅ **Structured JSON logging with zerolog**
- ✅ **Request/response logging middleware with Loki labels**
- ✅ **OpenTelemetry tracing (OTLP gRPC → Tempo)**
- ✅ **Prometheus metrics endpoint (`/metrics`)**
- ✅ Viper config management (YAML + ENV)

## Kanban Tasks

- `t_d1cdd7a9` — Design PostgreSQL database schema and migrations (architect)

## Build & Run

```bash
# This component is primarily a library/migration source
# Other components import the SQL or Go types

# Run migrations manually
psql $DATABASE_URL -f migrations/001_init.sql

# Docker (for migration runner if built)
docker build -t pamawas-schema .
docker run -e DATABASE_URL="postgres://..." pamawas-schema migrate
```

## Schema Design Principles

1. **Text IDs** — UUIDs as TEXT for flexibility across languages
2. **JSONB for flexible data** — labels, raw_payload for schema evolution
3. **CASCADE deletes** — Clean up child records when parent deleted
4. **CHECK constraints** — Evidence type enum, confidence bounds
5. **TEXT[] for arrays** — affected_services, channels (PostgreSQL native)
6. **TIMESTAMPTZ** — Always use timezone-aware timestamps

## Adding New Migrations

1. Create new file: `migrations/002_description.sql`
2. Use sequential numbering
3. Make migrations idempotent where possible (IF NOT EXISTS)
4. Test against clean database
5. Update shared Go types if needed