package config

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/spf13/viper"
)

type Config struct {
	DatabaseURL   string
	MigrationsDir string
	Port          string
	UseEmbedded   bool
}

func Load() Config {
	v := viper.New()
	v.SetConfigName("config")
	v.SetConfigType("yaml")
	v.AddConfigPath(".")
	v.AddConfigPath("./config")
	v.AddConfigPath("/etc/pamawas/")
	v.SetEnvPrefix("PAMAWAS_SCHEMA")
	v.AutomaticEnv()

	// Also read from DATABASE_URL directly for CI compatibility
	v.BindEnv("database_url", "DATABASE_URL")
	v.BindEnv("use_embedded_migrations", "USE_EMBEDDED_MIGRATIONS")

	// Defaults
	v.SetDefault("port", "8080")
	v.SetDefault("use_embedded_migrations", false)

	if err := v.ReadInConfig(); err != nil {
		if _, ok := err.(viper.ConfigFileNotFoundError); !ok {
			panic(fmt.Sprintf("failed to read config: %v", err))
		}
	}

	cfg := Config{
		DatabaseURL:   v.GetString("database_url"),
		MigrationsDir: v.GetString("migrations_dir"),
		Port:          v.GetString("port"),
		UseEmbedded:   v.GetBool("use_embedded_migrations"),
	}

	if cfg.DatabaseURL == "" {
		panic("DATABASE_URL not set (config file or PAMAWAS_SCHEMA_DATABASE_URL env var or DATABASE_URL)")
	}
	if cfg.MigrationsDir == "" && !cfg.UseEmbedded {
		// Default to embedded migrations if not specified
		cfg.UseEmbedded = true
	}
	return cfg
}

func (c Config) Validate() error {
	if c.DatabaseURL == "" {
		return fmt.Errorf("database_url is required")
	}
	if c.Port == "" {
		return fmt.Errorf("port is required")
	}
	if !c.UseEmbedded && c.MigrationsDir != "" {
		if _, err := os.Stat(c.MigrationsDir); os.IsNotExist(err) {
			return fmt.Errorf("migrations_dir does not exist: %s", c.MigrationsDir)
		}
		if _, err := os.Stat(filepath.Join(c.MigrationsDir, "001_init.sql")); os.IsNotExist(err) {
			return fmt.Errorf("migrations_dir missing 001_init.sql")
		}
	}
	return nil
}
