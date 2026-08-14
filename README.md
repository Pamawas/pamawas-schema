# pamawas-schema

Shared types: common event schema, evidence schema, DB migrations

Language: Go/SQL (shared module)

## Purpose
Provides SQL schema definitions and migration scripts for the PostgreSQL database used by all Pamawas services.

## Migration Strategy
We use plain SQL migration files in the `migrations/` directory, named with a numeric prefix and descriptive name (e.g., `001_init.sql`). Apply them in order using your preferred migration tool (e.g., `golang-migrate`, `flyway`, or manually via `psql`).

## Tables
- `events`: normalized incoming events from webhooks
- `incidents`: correlated groups of events
- `incident_events`: many-to-many link between incidents and events
- `evidence`: findings from the investigation engine (fact, likely_cause, hypothesis, unknown)
- `reports`: generated reports sent to output channels

## TODO
- Add indexes for performance
- Consider adding timestamps (created_at, updated_at) where appropriate
- Add foreign key constraints with appropriate cascade behavior
- Optionally, generate Go structs from SQL using `sqlc` or similar