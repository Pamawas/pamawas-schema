package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/DATA-DOG/go-sqlmock"
)

func TestNewMigrationRunnerLoadsEmbeddedMigration(t *testing.T) {
	db, _, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if closeErr := db.Close(); closeErr != nil {
			t.Logf("failed to close db: %v", closeErr)
		}
	}()

	runner, err := NewMigrationRunner(db, "", true)
	if err != nil {
		t.Fatal(err)
	}
	if len(runner.migrations) == 0 || runner.migrations[0].Version != "001_init" || !strings.Contains(runner.migrations[0].SQL, "CREATE TABLE") {
		t.Fatalf("unexpected migrations: %#v", runner.migrations)
	}
}

func TestNewMigrationRunnerLoadsSortedSQLFilesOnly(t *testing.T) {
	dir := t.TempDir()
	for name, contents := range map[string]string{
		"010_last.sql":  "SELECT 10;",
		"002_first.sql": "SELECT 2;",
		"README.md":     "ignore",
	} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(contents), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Mkdir(filepath.Join(dir, "003_dir.sql"), 0o700); err != nil {
		t.Fatal(err)
	}
	db, _, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if closeErr := db.Close(); closeErr != nil {
			t.Logf("failed to close db: %v", closeErr)
		}
	}()

	runner, err := NewMigrationRunner(db, dir, false)
	if err != nil {
		t.Fatal(err)
	}
	if got := []string{runner.migrations[0].Version, runner.migrations[1].Version}; got[0] != "002_first" || got[1] != "010_last" {
		t.Fatalf("order = %v", got)
	}
}

func TestNewMigrationRunnerReportsMissingDirectory(t *testing.T) {
	db, _, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if closeErr := db.Close(); closeErr != nil {
			t.Logf("failed to close db: %v", closeErr)
		}
	}()
	_, err = NewMigrationRunner(db, filepath.Join(t.TempDir(), "missing"), false)
	if err == nil || !strings.Contains(err.Error(), "failed to read migrations directory") {
		t.Fatalf("error = %v", err)
	}
}

func TestRunAppliesPendingAndSkipsAppliedMigration(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if closeErr := db.Close(); closeErr != nil {
			t.Logf("failed to close db: %v", closeErr)
		}
	}()
	runner := &MigrationRunner{db: db, migrations: []Migration{{Version: "001", SQL: "SELECT 1"}, {Version: "002", SQL: "SELECT 2"}}}
	mock.ExpectExec("CREATE TABLE IF NOT EXISTS schema_migrations").WillReturnResult(sqlmock.NewResult(0, 0))
	mock.ExpectQuery("SELECT version FROM schema_migrations").WillReturnRows(sqlmock.NewRows([]string{"version"}).AddRow("001"))
	mock.ExpectBegin()
	mock.ExpectExec(regexp.QuoteMeta("SELECT 2")).WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectExec(regexp.QuoteMeta("INSERT INTO schema_migrations (version) VALUES ($1)")).WithArgs("002").WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectCommit()

	if err := runner.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestRunRollsBackWhenMigrationFails(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if closeErr := db.Close(); closeErr != nil {
			t.Logf("failed to close db: %v", closeErr)
		}
	}()
	runner := &MigrationRunner{db: db, migrations: []Migration{{Version: "001", SQL: "bad sql"}}}
	mock.ExpectExec("CREATE TABLE IF NOT EXISTS schema_migrations").WillReturnResult(sqlmock.NewResult(0, 0))
	mock.ExpectQuery("SELECT version FROM schema_migrations").WillReturnRows(sqlmock.NewRows([]string{"version"}))
	mock.ExpectBegin()
	mock.ExpectExec("bad sql").WillReturnError(errors.New("syntax error"))
	mock.ExpectRollback()

	err = runner.Run(context.Background())
	if err == nil || !strings.Contains(err.Error(), "failed to execute migration 001") {
		t.Fatalf("error = %v", err)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestGetAppliedMigrationsTreatsQueryFailureAsEmpty(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if closeErr := db.Close(); closeErr != nil {
			t.Logf("failed to close db: %v", closeErr)
		}
	}()
	mock.ExpectQuery("SELECT version").WillReturnError(errors.New("missing table"))

	got, err := (&MigrationRunner{db: db}).getAppliedMigrations(context.Background())
	if err != nil || len(got) != 0 {
		t.Fatalf("got=%v err=%v", got, err)
	}
}

func TestHealthHandlerReportsPendingMigrations(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if closeErr := db.Close(); closeErr != nil {
			t.Logf("failed to close db: %v", closeErr)
		}
	}()
	runner := &MigrationRunner{db: db, migrations: []Migration{{Version: "001"}, {Version: "002"}}}
	mock.ExpectQuery("SELECT version").WillReturnRows(sqlmock.NewRows([]string{"version"}).AddRow("001"))
	recorder := httptest.NewRecorder()

	runner.healthHandler(recorder, httptest.NewRequestWithContext(context.Background(), http.MethodGet, "/healthz", nil))

	var response HealthResponse
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if recorder.Code != http.StatusOK || response.Status != "pending_migrations" || len(response.Pending) != 1 || response.Pending[0] != "002" || len(response.Migrations) != 1 || response.Timestamp == "" {
		t.Fatalf("status=%d response=%#v", recorder.Code, response)
	}
}

func TestMapKeysReturnsSortedKeys(t *testing.T) {
	got := mapKeys(map[string]bool{"z": true, "a": true, "m": false})
	if strings.Join(got, ",") != "a,m,z" {
		t.Fatalf("mapKeys = %v", got)
	}
}

func TestEmbeddedMigrationsContainUsableMVPDataModel(t *testing.T) {
	db, _, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if closeErr := db.Close(); closeErr != nil {
			t.Logf("failed to close db: %v", closeErr)
		}
	}()

	runner, err := NewMigrationRunner(db, "", true)
	if err != nil {
		t.Fatal(err)
	}

	// The expected migrations, in order, each with the schema elements it must
	// introduce. Every migration is asserted through this table so adding one
	// does not add a branch to this test.
	expected := []struct {
		version  string
		snippets []string
	}{
		{
			// Compacted baseline: the whole MVP data model.
			version: "001_init",
			snippets: []string{
				// Core events & incidents
				"source_event_id", "occurred_at", "last_event_at", "correlation_reason",
				"investigation_runs", "investigation_outbox",
				"report_requests", "report_incidents",
				"delivery_attempts", "UNIQUE (run_id, ordinal)",
				// Idempotency records
				"idempotency_records",
				// Feedback and reviews
				"investigation_reviews", "report_feedback",
				"verdict IN ('correct', 'incorrect', 'partially_correct', 'unknown')",
				"rating IN ('useful', 'not_useful', 'wrong', 'missing_context')",
				// Metrics and logs
				"metrics", "logs", "evidence",
				// Outbox resolve notification
				"reason", "incident_created", "incident_resolved",
			},
		},
		{
			version:  "002_dead_letter",
			snippets: []string{"investigation_outbox_dead_letter", "dead_lettered_at", "safe_error_code", "request_key_hash"},
		},
		{
			version:  "003_evidence_source_and_recommendation",
			snippets: []string{"'recommendation'", "source_detail", "evidence_source_check"},
		},
		{
			version:  "004_incident_identity_indexes",
			snippets: []string{"incidents_env_title_started_idx", "incidents_affected_services_gin"},
		},
		{
			version:  "005_correlation_decisions",
			snippets: []string{"correlation_decisions", "'ignored'", "identity_key", "incidents_open_identity_key_idx"},
		},
		{
			version:  "006_reconcile_incident_state",
			snippets: []string{"grafana_fingerprint", "identity_key", "cond.status <> 'firing'"},
		},
		{
			version:  "007_report_request_incident",
			snippets: []string{"report_requests ADD COLUMN IF NOT EXISTS incident_id", "report_requests_incident_id_idx"},
		},
		{
			version:  "008_stale_verifications",
			snippets: []string{"stale_verifications", "idx_stale_verifications_status_next", "idx_stale_verifications_unreported"},
		},
		{
			version:  "009_fk_indexes",
			snippets: []string{"idx_investigation_outbox_incident_id", "idx_correlation_decisions_incident_id", "idx_stale_verifications_run_id"},
		},
	}

	if len(runner.migrations) != len(expected) {
		t.Fatalf("migration count = %d, want %d", len(runner.migrations), len(expected))
	}

	for i, want := range expected {
		got := runner.migrations[i]
		if got.Version != want.version {
			t.Fatalf("migration %d version = %q, want %q", i+1, got.Version, want.version)
		}
		for _, snippet := range want.snippets {
			if !strings.Contains(got.SQL, snippet) {
				t.Errorf("%s missing %q", want.version, snippet)
			}
		}
	}
}
