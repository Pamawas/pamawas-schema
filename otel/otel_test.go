package otel

import (
	"context"
	"testing"
)

func TestInitTracerDisabled(t *testing.T) {
	shutdown, err := InitTracer(Config{ServiceName: "schema", Enabled: false})
	if err != nil || shutdown == nil {
		t.Fatalf("expected non-nil shutdown and no error; err=%v", err)
	}
	if err := shutdown(context.Background()); err != nil {
		t.Fatalf("shutdown error: %v", err)
	}
}

func TestInitTracerWithoutEndpointIsDisabled(t *testing.T) {
	shutdown, err := InitTracer(Config{ServiceName: "schema", Enabled: true})
	if err != nil || shutdown == nil {
		t.Fatalf("expected non-nil shutdown and no error; err=%v", err)
	}
}

func TestTracerReturnsTracer(t *testing.T) {
	if got := Tracer("schema-test"); got == nil {
		t.Fatal("Tracer returned nil")
	}
}
