package main

import (
	"context"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func quietLogger() *slog.Logger { return slog.New(slog.NewTextHandler(io.Discard, nil)) }

func newTestHandler(readyState bool) http.Handler {
	var ready atomic.Bool
	ready.Store(readyState)
	return NewHandler(&ready, quietLogger())
}

func TestRoutes(t *testing.T) {
	tests := []struct {
		name       string
		method     string
		target     string
		ready      bool
		wantStatus int
		wantBody   string
		wantHeader map[string]string
	}{
		{name: "root returns 42", method: http.MethodGet, target: "/", ready: true,
			wantStatus: 200, wantBody: "42\n",
			wantHeader: map[string]string{"Content-Type": "text/plain; charset=utf-8"}},
		{name: "query string is ignored", method: http.MethodGet, target: "/?q=life", ready: true,
			wantStatus: 200, wantBody: "42\n"},
		{name: "HEAD has no body", method: http.MethodHead, target: "/", ready: true,
			wantStatus: 200, wantBody: ""},
		{name: "POST is not allowed", method: http.MethodPost, target: "/", ready: true,
			wantStatus: 405, wantHeader: map[string]string{"Allow": "GET, HEAD"}},
		{name: "DELETE is not allowed", method: http.MethodDelete, target: "/", ready: true,
			wantStatus: 405},
		{name: "unknown path is 404", method: http.MethodGet, target: "/43", ready: true,
			wantStatus: 404},
		{name: "liveness is up", method: http.MethodGet, target: "/healthz", ready: true,
			wantStatus: 200, wantBody: "ok\n"},
		{name: "liveness stays up while draining", method: http.MethodGet, target: "/healthz", ready: false,
			wantStatus: 200, wantBody: "ok\n"},
		{name: "readiness is up", method: http.MethodGet, target: "/readyz", ready: true,
			wantStatus: 200, wantBody: "ok\n"},
		{name: "readiness fails while draining", method: http.MethodGet, target: "/readyz", ready: false,
			wantStatus: 503, wantBody: "draining\n"},
		{name: "root still answers while draining", method: http.MethodGet, target: "/", ready: false,
			wantStatus: 200, wantBody: "42\n"},
	}

	// A real test server (not a recorder) so HEAD and 405 behave exactly as on the wire.
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			srv := httptest.NewServer(newTestHandler(tc.ready))
			defer srv.Close()

			req, err := http.NewRequest(tc.method, srv.URL+tc.target, nil)
			if err != nil {
				t.Fatal(err)
			}
			resp, err := srv.Client().Do(req)
			if err != nil {
				t.Fatal(err)
			}
			defer resp.Body.Close()
			body, _ := io.ReadAll(resp.Body)

			if resp.StatusCode != tc.wantStatus {
				t.Fatalf("status: got %d, want %d", resp.StatusCode, tc.wantStatus)
			}
			if tc.wantBody != "" || tc.method == http.MethodHead {
				if string(body) != tc.wantBody {
					t.Fatalf("body: got %q, want %q", body, tc.wantBody)
				}
			}
			for k, v := range tc.wantHeader {
				if got := resp.Header.Get(k); got != v {
					t.Fatalf("header %s: got %q, want %q", k, got, v)
				}
			}
		})
	}
}

func TestLoadConfig(t *testing.T) {
	env := func(m map[string]string) func(string) string {
		return func(k string) string { return m[k] }
	}

	t.Run("defaults", func(t *testing.T) {
		cfg, err := LoadConfig(env(nil))
		if err != nil {
			t.Fatal(err)
		}
		if cfg.Port != 8080 || cfg.ShutdownDelay != 5*time.Second || cfg.ShutdownTimeout != 15*time.Second {
			t.Fatalf("unexpected defaults: %+v", cfg)
		}
	})

	t.Run("valid overrides", func(t *testing.T) {
		cfg, err := LoadConfig(env(map[string]string{"PORT": "9090", "SHUTDOWN_DELAY": "0s", "SHUTDOWN_TIMEOUT": "3s"}))
		if err != nil {
			t.Fatal(err)
		}
		if cfg.Port != 9090 || cfg.ShutdownDelay != 0 || cfg.ShutdownTimeout != 3*time.Second {
			t.Fatalf("unexpected config: %+v", cfg)
		}
	})

	for _, bad := range []map[string]string{
		{"PORT": "abc"},
		{"PORT": "0"},
		{"PORT": "65536"},
		{"PORT": "-1"},
		{"SHUTDOWN_DELAY": "five"},
		{"SHUTDOWN_DELAY": "-1s"},
		{"SHUTDOWN_TIMEOUT": "10"},
	} {
		t.Run("rejects "+strings.TrimSpace(firstKV(bad)), func(t *testing.T) {
			if _, err := LoadConfig(env(bad)); err == nil {
				t.Fatalf("expected an error for %v", bad)
			}
		})
	}
}

func firstKV(m map[string]string) string {
	for k, v := range m {
		return k + "=" + v
	}
	return ""
}

// TestGracefulShutdown checks the drain sequence that keeps rolling updates
// free of errors: after the signal, /readyz turns 503 but / keeps answering
// until the delay is over, and then Serve returns without an error.
func TestGracefulShutdown(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	base := "http://" + ln.Addr().String()
	cfg := Config{ShutdownDelay: 500 * time.Millisecond, ShutdownTimeout: 2 * time.Second}

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- Serve(ctx, ln, cfg, quietLogger()) }()

	client := &http.Client{Timeout: time.Second}
	waitFor(t, func() bool { return get(client, base+"/readyz") == 200 })

	cancel() // same as SIGTERM

	waitFor(t, func() bool { return get(client, base+"/readyz") == 503 })
	if code := get(client, base+"/"); code != 200 {
		t.Fatalf("during drain: GET / got %d, want 200", code)
	}

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("Serve returned error: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Serve did not return after shutdown")
	}

	if code := get(client, base+"/"); code != 0 {
		t.Fatalf("after shutdown: expected connection refused, got status %d", code)
	}
}

func get(c *http.Client, url string) int {
	resp, err := c.Get(url)
	if err != nil {
		return 0
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	return resp.StatusCode
}

func waitFor(t *testing.T, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("condition not met in time")
}
