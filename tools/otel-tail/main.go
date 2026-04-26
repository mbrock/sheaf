// otel-tail prints OpenTelemetry spans from a Redis Stream to stdout as they
// arrive.
//
// The stream is populated by Sheaf's custom span processor
// (Sheaf.Tracing.RedisSinkProcessor); this tool is the consumer side.
//
// To pick the right stream when no flag is passed, otel-tail looks at
// SHEAF_OTEL_STREAM, then derives `otel:spans:<SHEAF_NODE_BASENAME>` (or
// `otel:spans:sheaf` if neither is set). Because Sheaf is typically run as a
// systemd service whose env doesn't leak into interactive shells, otel-tail
// also auto-loads the `.env` file at the root of the checkout it lives in
// before reading those vars, so running `bin/otel-tail` in a fresh shell
// inside a sheaf checkout still hits that instance's stream.
package main

import (
	"context"
	"flag"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/mbrock/sheaf/tools/otel-tail/internal/otelstream"
	"github.com/redis/go-redis/v9"
)

func main() {
	loadDotEnvFromCheckout()

	redisURL := flag.String("redis-url", envDefault("SHEAF_OTEL_REDIS_URL", "redis://localhost:6379"), "Redis URL")
	stream := flag.String("stream", otelstream.DefaultStream(), "Redis stream key")
	backfill := flag.Int64("backfill", 0, "Print the last N spans before tailing live")
	jsonOut := flag.Bool("json", false, "Output raw JSON, one object per line")
	noColor := flag.Bool("no-color", false, "Disable ANSI colors")
	verbose := flag.Bool("v", false, "Print all attributes, not just promoted ones")
	flag.Parse()

	if *noColor || os.Getenv("NO_COLOR") != "" {
		disableColors()
	}

	opts, err := redis.ParseURL(*redisURL)
	if err != nil {
		log.Fatalf("invalid redis URL: %v", err)
	}
	rdb := redis.NewClient(opts)
	defer rdb.Close()

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	// go-redis's XRead can sit on a kernel read while Redis holds it open; ctx
	// cancellation alone doesn't always abort promptly. Closing the client from
	// a watcher goroutine keeps Ctrl-C responsive for terminal users.
	go func() {
		<-ctx.Done()
		_ = rdb.Close()
	}()

	if err := rdb.Ping(ctx).Err(); err != nil {
		log.Fatalf("redis ping failed: %v", err)
	}

	printer := NewSpanPrinter(os.Stdout, os.Stderr, SpanPrinterOptions{
		JSON:    *jsonOut,
		Verbose: *verbose,
	})
	tailer := otelstream.RedisTailer{
		Client: rdb,
		Stream: *stream,
		OnReadError: func(err error) {
			log.Printf("xread: %v (retrying)", err)
		},
	}

	err = tailer.Tail(ctx, otelstream.TailOptions{Backfill: *backfill}, printer.PrintEntry)
	if err != nil && ctx.Err() == nil {
		log.Fatalf("otel tail: %v", err)
	}
}
