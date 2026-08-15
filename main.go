package main

import (
	"context"
	"database/sql"
	"embed"
	"encoding/json"
	"fmt"
	"io/fs"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	_ "github.com/lib/pq"
)

//go:embed migrations/*.sql
var embeddedMigrations embed.FS

type Config struct {
	DatabaseURL    string
	MigrationsDir  string
	Port           string
	UseEmbedded    bool
}

func loadConfig() Config {
	cfg := Config{
		DatabaseURL:   os.Getenv("DATABASE_URL"),
		MigrationsDir: os.Getenv("MIGRATIONS_DIR"),
		Port:          getEnv("PORT", "8080"),
		UseEmbedded:   os.Getenv("USE_EMBEDDED_MIGRATIONS") == "true",
	}

	if cfg.DatabaseURL == "" {
		log.Fatal("DATABASE_URL environment variable not set")
	}
	if cfg.MigrationsDir == "" && !cfg.UseEmbedded {
		cfg.MigrationsDir = "/migrations"
	}
	return cfg
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

type Migration struct {
	Version string
	SQL     string
}

type MigrationRunner struct {
	db         *sql.DB
	migrations []Migration
}

func NewMigrationRunner(db *sql.DB, migrationsDir string, useEmbedded bool) (*MigrationRunner, error) {
	mr := &MigrationRunner{db: db}

	var err error
	if useEmbedded {
		mr.migrations, err = mr.loadEmbeddedMigrations()
	} else {
		mr.migrations, err = mr.loadMigrationsFromDir(migrationsDir)
	}
	if err != nil {
		return nil, fmt.Errorf("failed to load migrations: %w", err)
	}

	log.Printf("Loaded %d migrations", len(mr.migrations))
	for _, m := range mr.migrations {
		log.Printf("  - %s", m.Version)
	}
	return mr, nil
}

func (mr *MigrationRunner) loadEmbeddedMigrations() ([]Migration, error) {
	entries, err := fs.ReadDir(embeddedMigrations, "migrations")
	if err != nil {
		return nil, err
	}

	var migrations []Migration
	for _, entry := range entries {
		if !strings.HasSuffix(entry.Name(), ".sql") {
			continue
		}
		content, err := embeddedMigrations.ReadFile(filepath.Join("migrations", entry.Name()))
		if err != nil {
			return nil, err
		}
		version := strings.TrimSuffix(entry.Name(), ".sql")
		migrations = append(migrations, Migration{Version: version, SQL: string(content)})
	}

	sort.Slice(migrations, func(i, j int) bool {
		return migrations[i].Version < migrations[j].Version
	})
	return migrations, nil
}

func (mr *MigrationRunner) loadMigrationsFromDir(dir string) ([]Migration, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("failed to read migrations directory %s: %w", dir, err)
	}

	var migrations []Migration
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".sql") {
			continue
		}
		path := filepath.Join(dir, entry.Name())
		content, err := os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("failed to read migration %s: %w", path, err)
		}
		version := strings.TrimSuffix(entry.Name(), ".sql")
		migrations = append(migrations, Migration{Version: version, SQL: string(content)})
	}

	sort.Slice(migrations, func(i, j int) bool {
		return migrations[i].Version < migrations[j].Version
	})
	return migrations, nil
}

func (mr *MigrationRunner) ensureMigrationsTable(ctx context.Context) error {
	query := `
		CREATE TABLE IF NOT EXISTS schema_migrations (
			version TEXT PRIMARY KEY,
			applied_at TIMESTAMPTZ DEFAULT NOW()
		)
	`
	_, err := mr.db.ExecContext(ctx, query)
	return err
}

func (mr *MigrationRunner) getAppliedMigrations(ctx context.Context) (map[string]bool, error) {
	rows, err := mr.db.QueryContext(ctx, "SELECT version FROM schema_migrations")
	if err != nil {
		// Table might not exist yet
		return make(map[string]bool), nil
	}
	defer rows.Close()

	applied := make(map[string]bool)
	for rows.Next() {
		var version string
		if err := rows.Scan(&version); err != nil {
			return nil, err
		}
		applied[version] = true
	}
	return applied, rows.Err()
}

func (mr *MigrationRunner) Run(ctx context.Context) error {
	log.Println("Starting migration runner...")

	// Ensure migrations table exists
	if err := mr.ensureMigrationsTable(ctx); err != nil {
		return fmt.Errorf("failed to ensure migrations table: %w", err)
	}

	// Get already applied migrations
	applied, err := mr.getAppliedMigrations(ctx)
	if err != nil {
		return fmt.Errorf("failed to get applied migrations: %w", err)
	}
	log.Printf("Already applied migrations: %d", len(applied))

	// Run pending migrations
	for _, migration := range mr.migrations {
		if applied[migration.Version] {
			log.Printf("Skipping already applied migration: %s", migration.Version)
			continue
		}

		log.Printf("Applying migration: %s", migration.Version)
		start := time.Now()

		tx, err := mr.db.BeginTx(ctx, nil)
		if err != nil {
			return fmt.Errorf("failed to begin transaction for %s: %w", migration.Version, err)
		}

		// Execute migration SQL
		if _, err := tx.ExecContext(ctx, migration.SQL); err != nil {
			tx.Rollback()
			return fmt.Errorf("failed to execute migration %s: %w", migration.Version, err)
		}

		// Record migration as applied
		if _, err := tx.ExecContext(ctx, "INSERT INTO schema_migrations (version) VALUES ($1)", migration.Version); err != nil {
			tx.Rollback()
			return fmt.Errorf("failed to record migration %s: %w", migration.Version, err)
		}

		if err := tx.Commit(); err != nil {
			return fmt.Errorf("failed to commit migration %s: %w", migration.Version, err)
		}

		log.Printf("Applied migration %s in %v", migration.Version, time.Since(start))
	}

	log.Println("All migrations applied successfully")
	return nil
}

type HealthResponse struct {
	Status     string   `json:"status"`
	Migrations []string `json:"applied_migrations,omitempty"`
	Pending    []string `json:"pending_migrations,omitempty"`
	Timestamp  string   `json:"timestamp"`
}

func (mr *MigrationRunner) healthHandler(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	applied, err := mr.getAppliedMigrations(ctx)
	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(HealthResponse{
			Status:    "unhealthy",
			Timestamp: time.Now().UTC().Format(time.RFC3339),
		})
		return
	}

	var pending []string
	for _, m := range mr.migrations {
		if !applied[m.Version] {
			pending = append(pending, m.Version)
		}
	}

	status := "healthy"
	if len(pending) > 0 {
		status = "pending_migrations"
	}

	w.Header().Set("Content-Type", "application/json")
	if status == "healthy" {
		w.WriteHeader(http.StatusOK)
	} else {
		w.WriteHeader(http.StatusOK) // Still 200, but with pending info
	}

	json.NewEncoder(w).Encode(HealthResponse{
		Status:     status,
		Migrations: mapKeys(applied),
		Pending:    pending,
		Timestamp:  time.Now().UTC().Format(time.RFC3339),
	})
}

func mapKeys(m map[string]bool) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func main() {
	cfg := loadConfig()

	// Connect to database
	db, err := sql.Open("postgres", cfg.DatabaseURL)
	if err != nil {
		log.Fatalf("Failed to open database: %v", err)
	}
	defer db.Close()

	// Test connection with retries
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	for i := 0; i < 30; i++ {
		if err := db.PingContext(ctx); err == nil {
			break
		}
		log.Printf("Waiting for database... (%d/30)", i+1)
		time.Sleep(1 * time.Second)
	}

	if err := db.PingContext(ctx); err != nil {
		log.Fatalf("Failed to connect to database after retries: %v", err)
	}

	log.Println("Connected to database")

	// Create migration runner
	runner, err := NewMigrationRunner(db, cfg.MigrationsDir, cfg.UseEmbedded)
	if err != nil {
		log.Fatalf("Failed to create migration runner: %v", err)
	}

	// Run migrations
	if err := runner.Run(ctx); err != nil {
		log.Fatalf("Migration failed: %v", err)
	}

	// Start HTTP server for health checks
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", runner.healthHandler)
	mux.HandleFunc("/ready", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		json.NewEncoder(w).Encode(map[string]string{"status": "ready"})
	})

	server := &http.Server{
		Addr:    ":" + cfg.Port,
		Handler: mux,
	}

	log.Printf("Starting migration runner health server on :%s", cfg.Port)
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("Server failed: %v", err)
	}
}