package otelstream

import "encoding/json"

// Span mirrors the JSON shape produced by Sheaf.Tracing.SpanEncoder. Fields
// that are nil/missing are dropped on the producer side, so most of these
// pointers/maps are optional.
type Span struct {
	TraceID       string         `json:"trace_id"`
	SpanID        string         `json:"span_id"`
	ParentSpanID  string         `json:"parent_span_id,omitempty"`
	Name          string         `json:"name"`
	Kind          string         `json:"kind"`
	StartUnixNano int64          `json:"start_unix_nano"`
	EndUnixNano   int64          `json:"end_unix_nano"`
	DurationUs    int64          `json:"duration_us"`
	Status        *Status        `json:"status,omitempty"`
	Attributes    map[string]any `json:"attributes,omitempty"`
	Scope         map[string]any `json:"scope,omitempty"`
}

type Status struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// Entry is one OpenTelemetry span payload as it appeared in the Redis Stream.
type Entry struct {
	ID  string
	Raw string
}

func DecodeSpan(raw string) (Span, error) {
	var span Span
	err := json.Unmarshal([]byte(raw), &span)
	return span, err
}
