package main

import (
	"fmt"
	"strings"

	"github.com/mbrock/sheaf/tools/otel-tail/internal/otelstream"
)

// The tree renderer materializes the current span buffer into a fully
// reconstructed view every time something changes. Because this is a TUI
// and the model is small (≤ maxTUIEntries spans), we don't need to maintain
// an append-only log: a span that arrives after its parent simply slots
// under that parent on the next render.

type lineKind int

const (
	lineKindSpan      lineKind = iota // "* name  duration  T+offset"
	lineKindPredicate                 // "¶ verb value"
	lineKindError                     // decoder error from the redis stream
)

// renderedLine is one row of the tree. The body is pre-styled; depth is
// applied at view time so resizing doesn't force a re-style.
type renderedLine struct {
	kind     lineKind
	depth    int
	rendered string
	spanID   string // empty unless kind == lineKindSpan; used for sticky selection
}

// predicate is one ¶ line worth of content: a verb phrase, a value, and a
// hint at how the value should be styled.
type predicate struct {
	verb     string
	value    string
	valueFor string // role-ish hint: "info", "warning", "error", "muted", or ""
}

// predicatesOf builds the ordered list of ¶ lines for a span. Duration is
// *not* repeated here because the span's own header line already shows it.
// Promoted attributes follow in inlineAttrs order; status errors come last
// so they stay visible.
func predicatesOf(s otelstream.Span) []predicate {
	out := []predicate{}
	for _, key := range inlineAttrs {
		v, ok := s.Attributes[key]
		if !ok {
			continue
		}
		out = append(out, predicateFor(key, formatValue(v)))
	}
	if s.Status != nil && s.Status.Code == "error" {
		msg := s.Status.Message
		if msg == "" {
			msg = "error"
		}
		out = append(out, predicate{
			verb:     "errored:",
			value:    msg,
			valueFor: "error",
		})
	}
	return out
}

func predicateFor(key, value string) predicate {
	switch key {
	case "http.response.status_code":
		role := "info"
		if strings.HasPrefix(value, "4") || strings.HasPrefix(value, "5") {
			role = "error"
		}
		return predicate{verb: "returned status", value: value, valueFor: role}
	case "http.request.method":
		return predicate{verb: "had method", value: value, valueFor: "info"}
	case "http.route":
		return predicate{verb: "matched route", value: value, valueFor: "info"}
	case "sheaf.row_count":
		return predicate{verb: "returned", value: value + " rows", valueFor: "info"}
	case "sheaf.statement_count":
		return predicate{verb: "had", value: value + " statements", valueFor: "info"}
	case "sheaf.body_bytes":
		return predicate{verb: "had body of", value: value + " bytes", valueFor: "info"}
	case "sheaf.graph":
		return predicate{verb: "named graph", value: value, valueFor: "info"}
	case "sheaf.media_type":
		return predicate{verb: "had media type", value: value, valueFor: "info"}
	case "db.operation":
		return predicate{verb: "did", value: value, valueFor: "info"}
	case "db.system":
		return predicate{verb: "spoke to", value: value, valueFor: "info"}
	case "server.address":
		return predicate{verb: "at", value: value, valueFor: "info"}
	case "server.port":
		return predicate{verb: "on port", value: value, valueFor: "info"}
	case "net.peer.name":
		return predicate{verb: "peered with", value: value, valueFor: "info"}
	case "net.peer.port":
		return predicate{verb: "via port", value: value, valueFor: "info"}
	default:
		return predicate{verb: shortKey(key), value: value, valueFor: ""}
	}
}

// formatOffset returns "T+x.ys" relative to the trace's earliest seen
// start. Unknown returns empty.
func formatOffset(traceStartNs, eventNs int64) string {
	if traceStartNs == 0 || eventNs == 0 {
		return ""
	}
	dt := eventNs - traceStartNs
	if dt < 0 {
		return ""
	}
	return fmt.Sprintf("T+%.1fs", float64(dt)/1e9)
}
