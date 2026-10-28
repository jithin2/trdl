// TRDL, "The Responding Dark Laughter": an HTTP service that returns 42.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"sync/atomic"
	"syscall"
	"time"
)

// Config is read from environment variables (12-factor style).
type Config struct {
	Port            int           // PORT, default 8080
	ShutdownDelay   time.Duration // SHUTDOWN_DELAY, default 5s: time to stay up after SIGTERM while endpoints update
	ShutdownTimeout time.Duration // SHUTDOWN_TIMEOUT, default 15s: max time to finish in-flight requests
}

// LoadConfig reads and validates the configuration.
// A bad value is an error, never a silent fallback to the default.
func LoadConfig(getenv func(string) string) (Config, error) {
	cfg := Config{Port: 8080, ShutdownDelay: 5 * time.Second, ShutdownTimeout: 15 * time.Second}

	if v := getenv("PORT"); v != "" {
		p, err := strconv.Atoi(v)
		if err != nil || p < 1 || p > 65535 {
			return cfg, fmt.Errorf("PORT must be a number from 1 to 65535, got %q", v)
		}
		cfg.Port = p
	}

	durations := []struct {
		name string
		dst  *time.Duration
	}{
		{"SHUTDOWN_DELAY", &cfg.ShutdownDelay},
		{"SHUTDOWN_TIMEOUT", &cfg.ShutdownTimeout},
	}
	for _, d := range durations {
		v := getenv(d.name)
		if v == "" {
			continue
		}
		parsed, err := time.ParseDuration(v)
		if err != nil || parsed < 0 {
			return cfg, fmt.Errorf("%s must be a duration like 5s, got %q", d.name, v)
		}
		*d.dst = parsed
	}
	return cfg, nil
}

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))

	cfg, err := LoadConfig(os.Getenv)
	if err != nil {
		logger.Error("invalid configuration", "error", err)
		os.Exit(2)
	}

	ln, err := net.Listen("tcp", fmt.Sprintf(":%d", cfg.Port))
	if err != nil {
		logger.Error("cannot listen", "port", cfg.Port, "error", err)
		os.Exit(1)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	if err := Serve(ctx, ln, cfg, logger); err != nil {
		logger.Error("server stopped with error", "error", err)
		os.Exit(1)
	}
	logger.Info("server stopped cleanly")
}

// Serve runs the server until ctx is cancelled (SIGTERM), then drains:
//  1. mark not ready, so /readyz returns 503
//  2. keep serving for ShutdownDelay, so Kubernetes can remove the pod from
//     the Service endpoints before we stop accepting connections
//  3. stop accepting new connections and wait up to ShutdownTimeout for
//     in-flight requests to finish
func Serve(ctx context.Context, ln net.Listener, cfg Config, logger *slog.Logger) error {
	var ready atomic.Bool

	srv := &http.Server{
		Handler:           NewHandler(&ready, logger),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    16 << 10,
		ErrorLog:          slog.NewLogLogger(logger.Handler(), slog.LevelWarn),
	}

	serveErr := make(chan error, 1)
	go func() {
		ready.Store(true)
		logger.Info("listening", "addr", ln.Addr().String())
		serveErr <- srv.Serve(ln)
	}()

	select {
	case err := <-serveErr:
		// The server died on its own. Exit non-zero so Kubernetes restarts us.
		return err
	case <-ctx.Done():
	}

	ready.Store(false)
	logger.Info("shutdown signal received, draining", "delay", cfg.ShutdownDelay.String())
	time.Sleep(cfg.ShutdownDelay)

	shutdownCtx, cancel := context.WithTimeout(context.Background(), cfg.ShutdownTimeout)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		return fmt.Errorf("graceful shutdown: %w", err)
	}
	if err := <-serveErr; err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}
