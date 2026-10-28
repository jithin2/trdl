package main

import (
	"log/slog"
	"net/http"
	"sync/atomic"
	"time"
)

// Answer is the value TRDL returns.
const Answer = "42"

// NewHandler builds the HTTP routes.
//
//	GET  /         returns "42"
//	GET  /healthz  liveness: the process is alive
//	GET  /readyz   readiness: 200 while serving, 503 while draining
//
// The Go 1.22+ mux gives HEAD for free on GET routes, answers 405 with an
// Allow header for other methods, and 404 for unknown paths.
func NewHandler(ready *atomic.Bool, logger *slog.Logger) http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, _ *http.Request) {
		writeText(w, http.StatusOK, Answer+"\n")
	})

	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		writeText(w, http.StatusOK, "ok\n")
	})

	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, _ *http.Request) {
		if !ready.Load() {
			writeText(w, http.StatusServiceUnavailable, "draining\n")
			return
		}
		writeText(w, http.StatusOK, "ok\n")
	})

	return accessLog(logger, mux)
}

func writeText(w http.ResponseWriter, status int, body string) {
	h := w.Header()
	h.Set("Content-Type", "text/plain; charset=utf-8")
	h.Set("Cache-Control", "no-store")
	h.Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(status)
	_, _ = w.Write([]byte(body))
}

// statusRecorder captures the status code for the access log.
type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

// accessLog writes one JSON line per request to stdout.
// Probe calls are skipped so they do not flood the logs.
func accessLog(logger *slog.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/healthz" || r.URL.Path == "/readyz" {
			next.ServeHTTP(w, r)
			return
		}
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		logger.Info("request",
			"method", r.Method,
			"path", r.URL.Path,
			"status", rec.status,
			"duration_ms", float64(time.Since(start).Microseconds())/1000,
			"remote", r.RemoteAddr,
		)
	})
}
