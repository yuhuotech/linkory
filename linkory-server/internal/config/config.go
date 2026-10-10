package config

import (
	"os"
	"strconv"
	"strings"
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
	WebDir           string // optional: a Flutter web build served on every path the API does not use
	// CORSOrigins lists the page origins (https://my.example.com) allowed to call this server from a browser; empty = same origin only.
	CORSOrigins []string
	// WebPrefix is the URL path the web build is served under (default "/"; "/web/" keeps "/" free for a home page).
	WebPrefix string
	// WebCustomServer lets the web page served here also sign in to other servers (the sign-in page then offers it).
	WebCustomServer bool
}

func Load() Config {
	return Config{
		Addr:             env("LINKORY_ADDR", ":8080"),
		MySQLDSN:         env("LINKORY_MYSQL_DSN", ""),
		AccessTokenTTL:   envDuration("LINKORY_ACCESS_TTL", 15*time.Minute),
		RefreshTokenTTL:  envDuration("LINKORY_REFRESH_TTL", 90*24*time.Hour),
		OfflineMsgTTL:    envDuration("LINKORY_OFFLINE_MSG_TTL", 30*24*time.Hour),
		JWTSecret:        env("LINKORY_JWT_SECRET", ""),
		WebDir:           env("LINKORY_WEB_DIR", ""),
		WebPrefix:        env("LINKORY_WEB_PREFIX", "/"),
		CORSOrigins:      envList("LINKORY_CORS_ORIGINS"),
		WebCustomServer:  env("LINKORY_WEB_ALLOW_CUSTOM_SERVER", "") == "true",
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

func envList(k string) []string {
	var out []string
	for _, v := range strings.Split(os.Getenv(k), ",") {
		if v = strings.TrimSpace(v); v != "" {
			out = append(out, strings.TrimSuffix(v, "/"))
		}
	}
	return out
}
