package database

import (
	"database/sql"
	"fmt"
	"io/fs"
	"sort"
	"strings"

	_ "github.com/go-sql-driver/mysql"
)

func Open(dsn string) (*sql.DB, error) {
	db, err := sql.Open("mysql", dsn)
	if err != nil {
		return nil, err
	}
	return db, db.Ping()
}

// Migrate applies *.sql files (sorted by name) that are not yet recorded in
// schema_migrations. Each file may hold several statements separated by ";\n".
func Migrate(db *sql.DB, files fs.FS) error {
	if _, err := db.Exec(`CREATE TABLE IF NOT EXISTS schema_migrations (
		version VARCHAR(255) PRIMARY KEY,
		applied_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
	) ENGINE=InnoDB`); err != nil {
		return err
	}
	names, err := fs.Glob(files, "*.sql")
	if err != nil {
		return err
	}
	sort.Strings(names)
	for _, name := range names {
		var n int
		if err := db.QueryRow(`SELECT COUNT(*) FROM schema_migrations WHERE version=?`, name).Scan(&n); err != nil {
			return err
		}
		if n > 0 {
			continue
		}
		body, err := fs.ReadFile(files, name)
		if err != nil {
			return err
		}
		for _, stmt := range strings.Split(string(body), ";\n") {
			if strings.TrimSpace(stmt) == "" {
				continue
			}
			if _, err := db.Exec(stmt); err != nil {
				return fmt.Errorf("migration %s: %w", name, err)
			}
		}
		if _, err := db.Exec(`INSERT INTO schema_migrations(version) VALUES(?)`, name); err != nil {
			return err
		}
	}
	return nil
}
