package main

import (
	"encoding/json"
	"fmt"
	"io"
	"sort"
	"strings"
	"time"

	"github.com/mbrock/sheaf/tools/otel-tail/internal/otelstream"
)

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

type SpanPrinterOptions struct {
	JSON    bool
	Verbose bool
}

type SpanPrinter struct {
	out     io.Writer
	errOut  io.Writer
	options SpanPrinterOptions
}

func NewSpanPrinter(out, errOut io.Writer, options SpanPrinterOptions) *SpanPrinter {
	return &SpanPrinter{out: out, errOut: errOut, options: options}
}

func (p *SpanPrinter) PrintEntry(entry otelstream.Entry) error {
	if p.options.JSON {
		_, err := fmt.Fprintln(p.out, entry.Raw)
		return err
	}

	span, err := otelstream.DecodeSpan(entry.Raw)
	if err != nil {
		_, _ = fmt.Fprintf(p.errOut, "decode error: %v\n", err)
		return nil
	}
	return p.printSpan(&span)
}

// nameColWidth is the fixed width of the name column on line 1. Names longer
// than this are truncated with an ellipsis. Tuned so that a typical line
// (timestamp + name + duration + kind) sits comfortably under 80 cols.
const nameColWidth = 38

func (p *SpanPrinter) printSpan(s *otelstream.Span) error {
	end := time.Unix(0, s.EndUnixNano).Local()
	durStr := formatDuration(s.DurationUs)

	color := kindColor(s.Kind)
	name := padOrTruncate(s.Name, nameColWidth)

	// Line 1: aligned columns so successive spans sit on top of each other
	// vertically. Duration is right-aligned in a 10-char field so the unit
	// suffix lines up.
	if _, err := fmt.Fprintf(p.out, "%s%s%s  %s%s%s  %s%10s%s  %s%s%s",
		colorGray, end.Format("15:04:05.000"), colorReset,
		color, name, colorReset,
		colorGray, durStr, colorReset,
		colorDim, s.Kind, colorReset,
	); err != nil {
		return err
	}
	if s.Status != nil && s.Status.Code == "error" {
		if _, err := fmt.Fprintf(p.out, "  %s✗%s", colorRed, colorReset); err != nil {
			return err
		}
	}
	if _, err := fmt.Fprintln(p.out); err != nil {
		return err
	}

	// Line 2: attributes, only when there's something to show.
	parts := attrParts(s, p.options.Verbose)
	if s.Status != nil && s.Status.Code == "error" && s.Status.Message != "" {
		parts = append(parts, fmt.Sprintf("%serror%s: %s%s%s",
			colorDim, colorReset,
			colorRed, s.Status.Message, colorReset))
	}
	if len(parts) == 0 {
		return nil
	}
	_, err := fmt.Fprintf(p.out, "  %s\n", strings.Join(parts, "   "))
	return err
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
func attrParts(s *otelstream.Span, verbose bool) []string {
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
