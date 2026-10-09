package config

import (
	"os"
	"strconv"
	"time"
)

type Config struct {
	Addr             string
	MySQLDSN         string
	AccessTokenTTL   time.Duration
	RefreshTokenTTL  time.Duration
	OfflineMsgTTL    time.Duration
	MaxTransferBytes int64
	JWTSecret        string
}

func Load() Config {
	return Config{
		Addr:             env("LINKORY_ADDR", ":8080"),
		MySQLDSN:         env("LINKORY_MYSQL_DSN", "linkory:linkory@tcp(127.0.0.1:3306)/linkory?parseTime=true&charset=utf8mb4&loc=UTC"),
		AccessTokenTTL:   envDuration("LINKORY_ACCESS_TTL", 15*time.Minute),
		RefreshTokenTTL:  envDuration("LINKORY_REFRESH_TTL", 30*24*time.Hour),
		OfflineMsgTTL:    envDuration("LINKORY_OFFLINE_MSG_TTL", 30*24*time.Hour),
		JWTSecret:        env("LINKORY_JWT_SECRET", ""),
		MaxTransferBytes: envInt64("LINKORY_MAX_TRANSFER_BYTES", 2<<30),
	}
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func envDuration(k string, def time.Duration) time.Duration {
	if v := os.Getenv(k); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			return d
		}
	}
	return def
}

func envInt64(k string, def int64) int64 {
	if v := os.Getenv(k); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil {
			return n
		}
	}
	return def
}
