# pamawas-schema

**Shared Database Schema & Migrations** — Canonical PostgreSQL schema for all Pamawas components. Includes migration runner service.

[![Go Version](https://img.shields.io/badge/Go-1.26+-00ADD8?logo=go)](https://go.dev/)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-15+-4169E1?logo=postgresql)](https://postgresql.org/)
[![Docker](https://img.shields.io/badge/Docker-Ready-2496ED?logo=docker)](https://docker.com/)

---

## Purpose

Single source of truth for the Pamawas data model. Contains all table definitions, migrations, and shared Go types. All components depend on this.

## Tables

### `events` — Raw normalized events from all ingestion sources
```sql
CREATE TABLE events (
    id TEXT PRIMARY KEY,
    source TEXT NOT NULL,           -- grafana, prometheus, loki, generic
    type TEXT NOT NULL,             -- alert, event, metric
    timestamp TIMESTAMPTZ NOT NULL,
    service TEXT,
    environment TEXT,
    severity TEXT,                  -- critical, high, warning, info, debug
    title TEXT,
    status TEXT,                    -- firing, resolved
    labels JSONB,
    raw_payload JSONB
);
```

### `incidents` — Correlated groups of events
```sql
CREATE TABLE incidents (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    status TEXT NOT NULL,           -- firing, resolved
    started_at TIMESTAMPTZ,
    resolved_at TIMESTAMPTZ,
    severity TEXT,
    affected_services TEXT[]
);
```

### `incident_events` — Many-to-many link
```sql
CREATE TABLE incident_events (
    incident_id TEXT NOT NULL REFERENCES incidents(id) ON DELETE CASCADE,
    event_id TEXT NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    PRIMARY KEY (incident_id, event_id)
);
```

### `evidence` — Investigation findings with classification
```sql
CREATE TABLE evidence (
    id TEXT PRIMARY KEY,
    incident_id TEXT NOT NULL REFERENCES incidents(id) ON DELETE CASCADE,
    type TEXT NOT NULL CHECK (type IN ('fact','likely_cause','hypothesis','unknown')),
    content TEXT NOT NULL,
    source TEXT,
    confidence DOUBLE PRECISION CHECK (confidence >= 0.0 AND confidence <= 1.0)
);
```

### `reports` — Generated and delivered reports
```sql
CREATE TABLE reports (
    id TEXT PRIMARY KEY,
    incident_id TEXT NOT NULL REFERENCES incidents(id) ON DELETE CASCADE,
    content TEXT NOT NULL,
    sent_at TIMESTAMPTZ,
    channels TEXT[]                 -- discord, telegram, email
);
```

## Migrations

Located in `migrations/`:
- `001_init.sql` — Initial schema with all 5 tables + indexes

## Migration Runner Service

A standalone service that auto-applies migrations on startup:

```bash
# Docker
docker run -e DATABASE_URL="postgres://user:pass@host:5432/db" \
  ghcr.io/yoganovvaindra/pamawas-schema:latest migrate

# With embedded migrations (no filesystem needed)
docker run -e DATABASE_URL="postgres://user:pass@host:5432/db" \
  -e USE_EMBEDDED_MIGRATIONS=true \
  ghcr.io/yoganovvaindra/pamawas-schema:latest migrate
```

Features:
- Idempotent (safe to run repeatedly)
- Version tracking in `schema_migrations` table
- Health endpoint (`/healthz`)
- Prometheus metrics (`/metrics`)

## Shared Go Types

```go
// Event represents the normalized event
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

## Quick Start

```bash
# Run migrations manually
psql $DATABASE_URL -f migrations/001_init.sql

# Or use the migration runner
go run main.go migrate

# Docker
docker build -t pamawas-schema .
docker run -e DATABASE_URL="postgres://..." pamawas-schema migrate
```

## Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| `DATABASE_URL` | PostgreSQL connection string | **Required** |
| `PORT` | HTTP server port (for health/metrics) | `8080` |
| `USE_EMBEDDED_MIGRATIONS` | Use embedded migrations instead of filesystem | `false` |
| `LOG_LEVEL` | debug, info, warn, error | `info` |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | Tempo OTLP gRPC endpoint | `tempo:4317` |

## Schema Design Principles

1. **Text IDs** — UUIDs as TEXT for flexibility across languages
2. **JSONB for flexible data** — labels, raw_payload for schema evolution
3. **CASCADE deletes** — Clean up child records when parent deleted
4. **CHECK constraints** — Evidence type enum, confidence bounds
5. **TEXT[] for arrays** — affected_services, channels (PostgreSQL native)
6. **TIMESTAMPTZ** — Always use timezone-aware timestamps

## Observability

| Feature | Endpoint |
|---------|----------|
| Prometheus Metrics | `/metrics` — migration status, duration, errors |
| JSON Logging | stdout — trace_id, span_id, service, method, path |
| OpenTelemetry | OTLP gRPC → Tempo:4317 |

## Adding New Migrations

1. Create new file: `migrations/002_description.sql`
2. Use sequential numbering
3. Make migrations idempotent where possible (`IF NOT EXISTS`)
4. Test against clean database
5. Update shared Go types if needed

## Related

- **Root README**: [../README.md](../README.md)
- **System Design (Domain Model)**: [../docs/system-design/domain-data-model.md](../docs/system-design/domain-data-model.md)
- **All Components**: [../pamawas-ingest/](../pamawas-ingest/) [../pamawas-correlator/](../pamawas-correlator/) [../pamawas-investigator/](../pamawas-investigator/) [../pamawas-reporter/](../pamawas-reporter/) [../pamawas-scheduler/](../pamawas-scheduler/)