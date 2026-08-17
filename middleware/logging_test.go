package middleware

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/rs/zerolog"
	"github.com/rs/zerolog/log"
)

func TestLoggingMiddlewarePropagatesLoggerAndRecordsResponse(t *testing.T) {
	var output bytes.Buffer
	old := log.Logger
	log.Logger = zerolog.New(&output)
	t.Cleanup(func() { log.Logger = old })

	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		logger := GetLoggerFromContext(r.Context())
		logger.Info().Msg("inside")
		w.WriteHeader(http.StatusCreated)
	})
	req := httptest.NewRequestWithContext(context.Background(), http.MethodPost, "/items?q=one", nil)
	req.Header.Set("X-Trace-ID", "trace-123")
	req.Header.Set("User-Agent", "unit-test")
	recorder := httptest.NewRecorder()

	LoggingMiddleware("schema", next).ServeHTTP(recorder, req)

	if recorder.Code != http.StatusCreated {
		t.Fatalf("status = %d", recorder.Code)
	}
	lines := bytes.Split(bytes.TrimSpace(output.Bytes()), []byte("\n"))
	if len(lines) != 2 {
		t.Fatalf("log lines = %d: %s", len(lines), output.String())
	}
	var event map[string]any
	if err := json.Unmarshal(lines[1], &event); err != nil {
		t.Fatal(err)
	}
	if event["service"] != "schema" || event["trace_id"] != "trace-123" || event["status"] != float64(201) || event["query"] != "q=one" {
		t.Fatalf("unexpected event: %#v", event)
	}
}

func TestErrorLoggingMiddlewareRecoversPanic(t *testing.T) {
	var output bytes.Buffer
	old := log.Logger
	log.Logger = zerolog.New(&output)
	t.Cleanup(func() { log.Logger = old })

	handler := ErrorLoggingMiddleware("schema", http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		panic("boom")
	}))
	recorder := httptest.NewRecorder()
	req := httptest.NewRequestWithContext(context.Background(), http.MethodGet, "/panic", nil)
	req.Header.Set("X-Trace-ID", "trace-panic")

	handler.ServeHTTP(recorder, req)

	if recorder.Code != http.StatusInternalServerError || !bytes.Contains(output.Bytes(), []byte("Panic recovered")) || !bytes.Contains(output.Bytes(), []byte("trace-panic")) {
		t.Fatalf("status=%d log=%s", recorder.Code, output.String())
	}
}

func TestAddContextFields(t *testing.T) {
	var output bytes.Buffer
	logger := zerolog.New(&output)
	ctx := logger.WithContext(context.Background())
	ctx = AddContextFields(ctx, map[string]interface{}{"incident": "inc-1", "attempt": 2})

	contextLogger := GetLoggerFromContext(ctx)
	contextLogger.Info().Msg("event")

	var event map[string]any
	if err := json.Unmarshal(output.Bytes(), &event); err != nil {
		t.Fatal(err)
	}
	if event["incident"] != "inc-1" || event["attempt"] != float64(2) {
		t.Fatalf("unexpected event: %#v", event)
	}
}
