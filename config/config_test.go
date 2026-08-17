package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func clearConfigEnv(t *testing.T) {
	t.Helper()
	for _, key := range []string{
		"PAMAWAS_SCHEMA_DATABASE_URL",
		"PAMAWAS_SCHEMA_MIGRATIONS_DIR",
		"PAMAWAS_SCHEMA_PORT",
		"PAMAWAS_SCHEMA_USE_EMBEDDED_MIGRATIONS",
	} {
		t.Setenv(key, "")
	}
}

func TestLoadFromEnvironmentUsesDefaultsAndEmbeddedMigrations(t *testing.T) {
	clearConfigEnv(t)
	t.Setenv("PAMAWAS_SCHEMA_DATABASE_URL", "postgres://example/test")
	t.Chdir(t.TempDir())

	cfg := Load()

	if cfg.DatabaseURL != "postgres://example/test" || cfg.Port != "8080" || !cfg.UseEmbedded {
		t.Fatalf("unexpected config: %#v", cfg)
	}
}

func TestLoadReadsConfigFileAndEnvironmentOverridesIt(t *testing.T) {
	clearConfigEnv(t)
	dir := t.TempDir()
	contents := "database_url: postgres://file/test\nport: '9000'\nmigrations_dir: migrations\n"
	if err := os.WriteFile(filepath.Join(dir, "config.yaml"), []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Chdir(dir)
	t.Setenv("PAMAWAS_SCHEMA_PORT", "9100")

	cfg := Load()

	if cfg.DatabaseURL != "postgres://file/test" || cfg.Port != "9100" || cfg.MigrationsDir != "migrations" || cfg.UseEmbedded {
		t.Fatalf("unexpected config: %#v", cfg)
	}
}

func TestLoadPanicsWithoutDatabaseURL(t *testing.T) {
	clearConfigEnv(t)
	t.Chdir(t.TempDir())
	defer func() {
		if r := recover(); r != nil {
			if msg, ok := r.(string); !ok || !strings.Contains(msg, "DATABASE_URL not set") {
				t.Fatalf("unexpected panic: %v", r)
			}
		} else {
			t.Fatal("expected panic")
		}
	}()
	Load()
}

func TestValidate(t *testing.T) {
	dir := t.TempDir()
	migration := filepath.Join(dir, "001_init.sql")
	if err := os.WriteFile(migration, []byte("SELECT 1;"), 0o600); err != nil {
		t.Fatal(err)
	}

	tests := []struct {
		name    string
		cfg     Config
		wantErr string
	}{
		{"valid embedded", Config{DatabaseURL: "db", Port: "8080", UseEmbedded: true}, ""},
		{"valid directory", Config{DatabaseURL: "db", Port: "8080", MigrationsDir: dir}, ""},
		{"missing database", Config{Port: "8080", UseEmbedded: true}, "database_url is required"},
		{"missing port", Config{DatabaseURL: "db", UseEmbedded: true}, "port is required"},
		{"missing directory", Config{DatabaseURL: "db", Port: "8080", MigrationsDir: filepath.Join(dir, "missing")}, "does not exist"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := tt.cfg.Validate()
			if tt.wantErr == "" && err != nil {
				t.Fatalf("Validate() error = %v", err)
			}
			if tt.wantErr != "" && (err == nil || !strings.Contains(err.Error(), tt.wantErr)) {
				t.Fatalf("Validate() error = %v, want containing %q", err, tt.wantErr)
			}
		})
	}
}
