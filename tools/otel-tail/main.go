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
	"bufio"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"

	"github.com/redis/go-redis/v9"
)

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

// inlineAttrs are attributes promoted into the one-line summary for any span
// that has them. Order matters: this is the order they're printed in.
var inlineAttrs = []string{
	"http.response.status_code",
	"http.request.method",
	"http.route",
	"sheaf.statement_count",
	"sheaf.row_count",
	"sheaf.body_bytes",
	"sheaf.graph",
	"sheaf.media_type",
	"db.operation",
	"db.system",
	"server.address",
	"server.port",
	"net.peer.name",
	"net.peer.port",
}

func main() {
	loadDotEnvFromCheckout()

	redisURL := flag.String("redis-url", envDefault("SHEAF_OTEL_REDIS_URL", "redis://localhost:6379"), "Redis URL")
	stream := flag.String("stream", defaultStream(), "Redis stream key")
	backfill := flag.Int("backfill", 0, "Print the last N spans before tailing live")
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

	// go-redis's XRead with Block:0 will sit on a kernel read for as long as
	// Redis chooses to hold it open; ctx cancellation alone doesn't always
	// abort the underlying connection promptly. Closing the client from a
	// watcher goroutine forces any pending read to error out, which makes
	// Ctrl-C feel instant.
	go func() {
		<-ctx.Done()
		_ = rdb.Close()
	}()

	if err := rdb.Ping(ctx).Err(); err != nil {
		log.Fatalf("redis ping failed: %v", err)
	}

	startID := "$"
	if *backfill > 0 {
		entries, err := rdb.XRevRangeN(ctx, *stream, "+", "-", int64(*backfill)).Result()
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			log.Fatalf("xrevrange: %v", err)
		}
		// XRevRange returns newest-first; flip so output reads in time order.
		for i := len(entries) - 1; i >= 0; i-- {
			handleEntry(entries[i], *jsonOut, *verbose)
			startID = entries[i].ID
		}
	}

	for {
		if ctx.Err() != nil {
			return
		}
		// A bounded block lets us poll ctx between reads even if the
		// connection-close path somehow misses (it shouldn't, but defence in
		// depth costs nothing).
		res, err := rdb.XRead(ctx, &redis.XReadArgs{
			Streams: []string{*stream, startID},
			Block:   2 * time.Second,
			Count:   100,
		}).Result()
		if err == redis.Nil {
			continue
		}
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			log.Printf("xread: %v (retrying)", err)
			time.Sleep(time.Second)
			continue
		}
		for _, s := range res {
			for _, msg := range s.Messages {
				handleEntry(msg, *jsonOut, *verbose)
				startID = msg.ID
			}
		}
	}
}

// defaultStream picks the stream name when no -stream flag is passed. The
// chain mirrors `config/runtime.exs`'s default so producer and consumer stay
// in sync.
func defaultStream() string {
	if explicit := os.Getenv("SHEAF_OTEL_STREAM"); explicit != "" {
		return explicit
	}

	basename := os.Getenv("SHEAF_NODE_BASENAME")
	if basename == "" {
		basename = "sheaf"
	}
	return "otel:spans:" + basename
}

func envDefault(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// loadDotEnvFromCheckout walks up from the otel-tail executable looking for a
// `.env` file at the root of a sheaf checkout, and merges its KEY=VALUE pairs
// into the process env without overriding values that are already set. This
// lets `bin/otel-tail` pick up SHEAF_OTEL_* and SHEAF_NODE_BASENAME from the
// checkout's `.env` even when running from an interactive shell where the
// systemd service env is not visible.
func loadDotEnvFromCheckout() {
	exe, err := os.Executable()
	if err != nil {
		return
	}

	dir := filepath.Dir(exe)
	for i := 0; i < 6; i++ {
		candidate := filepath.Join(dir, ".env")
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
			mergeDotEnv(candidate)
			return
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return
		}
		dir = parent
	}
}

func mergeDotEnv(path string) {
	f, err := os.Open(path)
	if err != nil {
		return
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		eq := strings.IndexByte(line, '=')
		if eq <= 0 {
			continue
		}
		key := strings.TrimSpace(line[:eq])
		value := strings.TrimSpace(line[eq+1:])
		if len(value) >= 2 {
			first, last := value[0], value[len(value)-1]
			if (first == '"' && last == '"') || (first == '\'' && last == '\'') {
				value = value[1 : len(value)-1]
			}
		}
		if _, present := os.LookupEnv(key); !present {
			os.Setenv(key, value)
		}
	}
}

func handleEntry(msg redis.XMessage, jsonOut, verbose bool) {
	raw, ok := msg.Values["data"].(string)
	if !ok {
		return
	}
	if jsonOut {
		fmt.Println(raw)
		return
	}
	var span Span
	if err := json.Unmarshal([]byte(raw), &span); err != nil {
		fmt.Fprintf(os.Stderr, "decode error: %v\n", err)
		return
	}
	printSpan(&span, verbose)
}

// nameColWidth is the fixed width of the name column on line 1. Names longer
// than this are truncated with an ellipsis. Tuned so that a typical line
// (timestamp + name + duration + kind) sits comfortably under 80 cols.
const nameColWidth = 38

func printSpan(s *Span, verbose bool) {
	end := time.Unix(0, s.EndUnixNano).Local()
	durStr := formatDuration(s.DurationUs)

	color := kindColor(s.Kind)
	name := padOrTruncate(s.Name, nameColWidth)

	// Line 1: aligned columns so successive spans sit on top of each other
	// vertically. Duration is right-aligned in a 10-char field so the unit
	// suffix lines up.
	fmt.Printf("%s%s%s  %s%s%s  %s%10s%s  %s%s%s",
		colorGray, end.Format("15:04:05.000"), colorReset,
		color, name, colorReset,
		colorGray, durStr, colorReset,
		colorDim, s.Kind, colorReset,
	)
	if s.Status != nil && s.Status.Code == "error" {
		fmt.Printf("  %s✗%s", colorRed, colorReset)
	}
	fmt.Println()

	// Line 2: attributes, only when there's something to show.
	parts := attrParts(s, verbose)
	if s.Status != nil && s.Status.Code == "error" && s.Status.Message != "" {
		parts = append(parts, fmt.Sprintf("%serror%s: %s%s%s",
			colorDim, colorReset,
			colorRed, s.Status.Message, colorReset))
	}
	if len(parts) == 0 {
		return
	}
	fmt.Printf("  %s\n", strings.Join(parts, "   "))
}

// padOrTruncate fits a string into exactly `n` runes, padding with spaces on
// the right or truncating with an ellipsis if it doesn't fit. Operates on
// runes so it handles UTF-8 correctly.
func padOrTruncate(s string, n int) string {
	runes := []rune(s)
	if len(runes) > n {
		return string(runes[:n-1]) + "…"
	}
	if len(runes) < n {
		return s + strings.Repeat(" ", n-len(runes))
	}
	return s
}

// attrParts returns a list of "key=value" snippets to print on the second
// line, in a stable display order: promoted attributes first, then everything
// else in alphabetical order if `verbose` is set. Keys are shortened to their
// last dotted component (`http.response.status_code` -> `status_code`) for
// brevity; this loses some semantic information, but is much easier to scan
// at a glance.
func attrParts(s *Span, verbose bool) []string {
	if len(s.Attributes) == 0 {
		return nil
	}
	parts := make([]string, 0, len(s.Attributes))
	seen := make(map[string]bool, len(inlineAttrs))
	for _, key := range inlineAttrs {
		if v, ok := s.Attributes[key]; ok {
			parts = append(parts, formatAttr(key, v))
			seen[key] = true
		}
	}
	if !verbose {
		return parts
	}
	keys := make([]string, 0, len(s.Attributes))
	for k := range s.Attributes {
		if !seen[k] {
			keys = append(keys, k)
		}
	}
	sort.Strings(keys)
	for _, k := range keys {
		parts = append(parts, formatAttr(k, s.Attributes[k]))
	}
	return parts
}

// formatAttr renders one attribute as a colored "key: value" pair. Keys are
// dimmed and shortened to their last dotted component; values are rendered
// normal-weight in their type-appropriate color so the eye lands on the data,
// not the labels.
func formatAttr(key string, v any) string {
	return fmt.Sprintf("%s%s%s: %s%s%s",
		colorDim, shortKey(key), colorReset,
		valueColor(v), formatValue(v), colorReset,
	)
}

func valueColor(v any) string {
	switch v.(type) {
	case string:
		return colorCyan
	case bool:
		return colorYellow
	case float64, int, int64:
		return colorMagenta
	default:
		return colorReset
	}
}

// shortKey returns the last dotted component of a key, or the whole key if it
// has no dots.
func shortKey(key string) string {
	if i := strings.LastIndex(key, "."); i >= 0 {
		return key[i+1:]
	}
	return key
}

func formatDuration(us int64) string {
	switch {
	case us < 1000:
		return fmt.Sprintf("%dµs", us)
	case us < 1_000_000:
		return fmt.Sprintf("%.2fms", float64(us)/1000)
	default:
		return fmt.Sprintf("%.2fs", float64(us)/1_000_000)
	}
}

func formatValue(v any) string {
	switch x := v.(type) {
	case string:
		if strings.ContainsAny(x, " \t\n\"") {
			return fmt.Sprintf("%q", x)
		}
		return x
	case float64:
		if x == float64(int64(x)) {
			return fmt.Sprintf("%d", int64(x))
		}
		return fmt.Sprintf("%g", x)
	default:
		b, _ := json.Marshal(v)
		return string(b)
	}
}

func kindColor(kind string) string {
	switch kind {
	case "server":
		return colorGreen
	case "client":
		return colorBlue
	case "producer":
		return colorYellow
	case "consumer":
		return colorCyan
	case "internal":
		return colorMagenta
	default:
		return colorReset
	}
}

var (
	colorReset   = "\x1b[0m"
	colorRed     = "\x1b[31m"
	colorGreen   = "\x1b[32m"
	colorYellow  = "\x1b[33m"
	colorBlue    = "\x1b[34m"
	colorMagenta = "\x1b[35m"
	colorCyan    = "\x1b[36m"
	colorGray    = "\x1b[90m"
	colorDim     = "\x1b[2m"
)

func disableColors() {
	colorReset = ""
	colorRed = ""
	colorGreen = ""
	colorYellow = ""
	colorBlue = ""
	colorMagenta = ""
	colorCyan = ""
	colorGray = ""
	colorDim = ""
}
