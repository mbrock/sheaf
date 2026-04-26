package otelstream

import "os"

// DefaultStream picks the stream name when no -stream flag is passed. The
// chain mirrors `config/runtime.exs`'s default so producer and consumer stay
// in sync.
func DefaultStream() string {
	if explicit := os.Getenv("SHEAF_OTEL_STREAM"); explicit != "" {
		return explicit
	}

	basename := os.Getenv("SHEAF_NODE_BASENAME")
	if basename == "" {
		basename = "sheaf"
	}
	return "otel:spans:" + basename
}
