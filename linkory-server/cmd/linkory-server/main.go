package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/linkory/linkory-server/internal/config"
	"github.com/linkory/linkory-server/internal/database"
	"github.com/linkory/linkory-server/internal/httpapi"
	"github.com/linkory/linkory-server/migrations"
)

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	cfg := config.Load()

	db, err := database.Open(cfg.MySQLDSN)
	if err != nil {
		log.Error("open database", "err", err)
		os.Exit(1)
	}
	defer db.Close()
	if err := database.Migrate(db, migrations.FS); err != nil {
		log.Error("migrate", "err", err)
		os.Exit(1)
	}

	srv := &http.Server{Addr: cfg.Addr, Handler: httpapi.NewRouter(db), ReadHeaderTimeout: 10 * time.Second}
	go func() {
		log.Info("listening", "addr", cfg.Addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error("serve", "err", err)
			os.Exit(1)
		}
	}()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	<-ctx.Done()
	shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutdown)
}
