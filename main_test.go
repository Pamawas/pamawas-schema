package main

import (
	"context"
	"database/sql"
	"embed"
	"fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	_ "github.com/lib/pq"
)

//go:embed migrations/*.sql
var embeddedMigrations embed.FS

// TestConfig holds test configuration
type TestConfig struct {
	DatabaseURL   string
	MigrationsDir string
}

// getTestConfig returns test configuration from environment or defaults
func getTestConfig() TestConfig {
	dbURL := os.Getenv("TEST_DATABASE_URL")
	if dbURL == "" {
		// Default to a test database - this will be skipped if not available
		dbURL = "postgres://pamawas:pamawas@localhost:5432/pamawas_test?sslmode=disable"
	}

	migrationsDir := os.Getenv("TEST_MIGRATIONS_DIR")
	if migrationsDir == "" {
		migrationsDir = "./migrations"
	}

	return TestConfig{
		DatabaseURL:   dbURL,
		MigrationsDir: migrationsDir,
	}
}

// TestMigrationRunner_Embedded tests the migration runner with embedded migrations
func TestMigrationRunner_Embedded(t *testing.T) {
	cfg := getTestConfig()

	// Skip if no test database available
	db, err := sql.Open("postgres", cfg.DatabaseURL)
	if err != nil {
		t.Skipf("Skipping test: cannot open database: %v", err)
	}
	defer db.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := db.PingContext(ctx); err != nil {
		t.Skipf("Skipping test: database not available: %v", err)
	}

	// Create a migration runner with embedded migrations
	runner, err := NewMigrationRunner(db, "", true) // useEmbedded = true
	if err != nil {
		t.Fatalf("Failed to create migration runner: %v", err)
	}

	// Verify migrations were loaded
	if len(runner.migrations) == 0 {
		t.Fatal("No migrations loaded from embedded filesystem")
	}

	t.Logf("Loaded %d embedded migrations", len(runner.migrations))
	for _, m := range runner.migrations {
		t.Logf("  - %s (%d chars)", m.Version, len(m.SQL))
	}

	// Ensure migrations table exists
	if err := runner.ensureMigrationsTable(ctx); err != nil {
		t.Fatalf("Failed to ensure migrations table: %v", err)
	}

	// Get applied migrations (should be empty initially)
	applied, err := runner.getAppliedMigrations(ctx)
	if err != nil {
		t.Fatalf("Failed to get applied migrations: %v", err)
	}

	t.Logf("Initially applied migrations: %d", len(applied))

	// Run migrations
	if err := runner.Run(ctx); err != nil {
		t.Fatalf("Migration failed: %v", err)
	}

	// Verify all migrations applied
	applied, err = runner.getAppliedMigrations(ctx)
	if err != nil {
		t.Fatalf("Failed to get applied migrations after run: %v", err)
	}

	if len(applied) != len(runner.migrations) {
		t.Errorf("Expected %d applied migrations, got %d", len(runner.migrations), len(applied))
	}

	t.Logf("Successfully applied %d migrations", len(applied))

	// Run again - should be idempotent
	if err := runner.Run(ctx); err != nil {
		t.Fatalf("Second migration run failed: %v", err)
	}

	applied, err = runner.getAppliedMigrations(ctx)
	if err != nil {
		t.Fatalf("Failed to get applied migrations after second run: %v", err)
	}

	if len(applied) != len(runner.migrations) {
		t.Errorf("Expected %d applied migrations after second run, got %d", len(runner.migrations), len(applied))
	}

	t.Log("Second run completed successfully (idempotent)")
}

// TestMigrationRunner_FromDirectory tests loading migrations from a directory
func TestMigrationRunner_FromDirectory(t *testing.T) {
	cfg := getTestConfig()

	// Create a temporary migrations directory
	tmpDir := t.TempDir()
	migrationsDir := filepath.Join(tmpDir, "migrations")
	if err := os.MkdirAll(migrationsDir, 0755); err != nil {
		t.Fatalf("Failed to create temp migrations dir: %v", err)
	}

	// Write test migration files
	testMigrations := []struct {
		name string
		sql  string
	}{
		{"001_test.sql", "CREATE TABLE IF NOT EXISTS test_table_1 (id TEXT PRIMARY KEY);"},
		{"002_test.sql", "CREATE TABLE IF NOT EXISTS test_table_2 (id TEXT PRIMARY KEY);"},
		{"003_test.sql", "CREATE TABLE IF NOT EXISTS test_table_3 (id TEXT PRIMARY KEY);"},
	}

	for _, m := range testMigrations {
		path := filepath.Join(migrationsDir, m.name)
		if err := os.WriteFile(path, []byte(m.sql), 0644); err != nil {
			t.Fatalf("Failed to write test migration: %v", err)
		}
	}

	db, err := sql.Open("postgres", cfg.DatabaseURL)
	if err != nil {
		t.Skipf("Skipping test: cannot open database: %v", err)
	}
	defer db.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := db.PingContext(ctx); err != nil {
		t.Skipf("Skipping test: database not available: %v", err)
	}

	// Create migration runner from directory
	runner, err := NewMigrationRunner(db, migrationsDir, false)
	if err != nil {
		t.Fatalf("Failed to create migration runner: %v", err)
	}

	if len(runner.migrations) != len(testMigrations) {
		t.Fatalf("Expected %d migrations, got %d", len(testMigrations), len(runner.migrations))
	}

	// Verify order
	for i, m := range runner.migrations {
		expectedVersion := testMigrations[i].name[:strings.Index(testMigrations[i].name, ".sql")]
		if m.Version != expectedVersion {
			t.Errorf("Migration %d: expected version %s, got %s", i, expectedVersion, m.Version)
		}
		if !strings.Contains(m.SQL, testMigrations[i].sql) {
			t.Errorf("Migration %d: SQL content mismatch", i)
		}
	}

	t.Logf("Successfully loaded %d migrations from directory", len(runner.migrations))
}

// TestMigrationRunner_HealthEndpoint tests the health check endpoint logic
func TestMigrationRunner_HealthEndpoint(t *testing.T) {
	cfg := getTestConfig()

	db, err := sql.Open("postgres", cfg.DatabaseURL)
	if err != nil {
		t.Skipf("Skipping test: cannot open database: %v", err)
	}
	defer db.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := db.PingContext(ctx); err != nil {
		t.Skipf("Skipping test: database not available: %v", err)
	}

	runner, err := NewMigrationRunner(db, "", true)
	if err != nil {
		t.Fatalf("Failed to create migration runner: %v", err)
	}

	// Ensure table exists
	if err := runner.ensureMigrationsTable(ctx); err != nil {
		t.Fatalf("Failed to ensure migrations table: %v", err)
	}

	// Test health check logic by calling the internal methods
	applied, err := runner.getAppliedMigrations(ctx)
	if err != nil {
		t.Fatalf("Failed to get applied migrations: %v", err)
	}

	var pending []string
	for _, m := range runner.migrations {
		if !applied[m.Version] {
			pending = append(pending, m.Version)
		}
	}

	status := "healthy"
	if len(pending) > 0 {
		status = "pending_migrations"
	}

	t.Logf("Health status: %s, applied: %d, pending: %d", status, len(applied), len(pending))
}

// TestMigrationSorting tests that migrations are sorted correctly
func TestMigrationSorting(t *testing.T) {
	// Create test migrations in random order
	migrations := []Migration{
		{Version: "003_test", SQL: "CREATE TABLE test3;"},
		{Version: "001_test", SQL: "CREATE TABLE test1;"},
		{Version: "010_test", SQL: "CREATE TABLE test10;"},
		{Version: "002_test", SQL: "CREATE TABLE test2;"},
	}

	// Sort using the same logic as the runner
	sort.Slice(migrations, func(i, j int) bool {
		return migrations[i].Version < migrations[j].Version
	})

	expectedOrder := []string{"001_test", "002_test", "003_test", "010_test"}
	for i, m := range migrations {
		if m.Version != expectedOrder[i] {
			t.Errorf("Position %d: expected %s, got %s", i, expectedOrder[i], m.Version)
		}
	}
}

// TestLoadEmbeddedMigrations tests loading from embedded filesystem
func TestLoadEmbeddedMigrations(t *testing.T) {
	// This tests the actual embedded migrations
	entries, err := fs.ReadDir(embeddedMigrations, "migrations")
	if err != nil {
		t.Fatalf("Failed to read embedded migrations: %v", err)
	}

	if len(entries) == 0 {
		t.Fatal("No embedded migrations found")
	}

	t.Logf("Found %d embedded migration files", len(entries))
	for _, entry := range entries {
		if strings.HasSuffix(entry.Name(), ".sql") {
			t.Logf("  - %s", entry.Name())
		}
	}
}