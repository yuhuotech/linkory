package main

import (
	"context"
	"crypto/rand"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/linkory/linkory-server/internal/admin"
	"github.com/linkory/linkory-server/internal/auth"
	"github.com/linkory/linkory-server/internal/config"
	"github.com/linkory/linkory-server/internal/database"
	"github.com/linkory/linkory-server/internal/httpapi"
	"github.com/linkory/linkory-server/internal/messaging"
	"github.com/linkory/linkory-server/migrations"
)

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	cfg := config.Load()

	if cfg.MySQLDSN == "" {
		log.Error("LINKORY_MYSQL_DSN is required (see linkory-server/.env.example)")
		os.Exit(1)
	}
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

	if len(os.Args) > 1 && os.Args[1] == "admin" {
		if err := adminCLI(db, os.Args[2:]); err != nil {
			log.Error("admin command", "err", err)
			os.Exit(1)
		}
		return
	}
	secret := []byte(cfg.JWTSecret)
	if len(secret) < 32 {
		log.Warn("LINKORY_JWT_SECRET missing or shorter than 32 bytes; using a random per-process secret (tokens invalid after restart)")
		secret = make([]byte, 32)
		_, _ = rand.Read(secret)
	}
	httpapi.MetricsToken = os.Getenv("LINKORY_METRICS_TOKEN")
	authSvc := auth.NewService(db, secret, cfg.AccessTokenTTL, cfg.RefreshTokenTTL)

	store := &messaging.Store{DB: db}
	hub := messaging.NewHub(db, store)
	adminSvc := admin.NewService(db, hub, int(cfg.OfflineMsgTTL.Hours()/24))
	adminSvc.SecureCookie = cfg.AdminCookieSecure
	if len(cfg.AdminTrustedProxies) > 0 {
		if err := adminSvc.SetTrustedProxies(cfg.AdminTrustedProxies); err != nil {
			log.Error("admin trusted proxies", "err", err)
			os.Exit(1)
		}
	}
	workerCtx, workerCancel := context.WithCancel(context.Background())
	defer workerCancel()
	go adminSvc.Run(workerCtx)
	go func() {
		for range time.Tick(time.Hour) {
			authSvc.PurgeTombstones(context.Background(), 30*24*time.Hour)
			authSvc.PurgeStaleWebDevices(context.Background(), 30*24*time.Hour)
		}
	}()

	srv := &http.Server{Addr: cfg.Addr, Handler: httpapi.NewRouter(db, authSvc, hub, cfg.OfflineMsgTTL, uint64(cfg.MaxTransferBytes), httpapi.Options{Admin: adminSvc, AdminDir: cfg.AdminDir, WebDir: cfg.WebDir, WebPrefix: cfg.WebPrefix, CORSOrigins: cfg.CORSOrigins, WebCustomServer: cfg.WebCustomServer}), ReadHeaderTimeout: 10 * time.Second}
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
