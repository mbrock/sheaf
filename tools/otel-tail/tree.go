package main

import (
	"fmt"
	"sort"
	"strings"

	"github.com/mbrock/sheaf/tools/otel-tail/internal/otelstream"
)

// The tree renderer materializes the current span buffer into a fully
// reconstructed view every time something changes. Because this is a TUI
// and the model is small (≤ maxTUIEntries spans), we don't need to maintain
// an append-only log: a span that arrives after its parent simply slots
// under that parent on the next render.

type spanTreeItem struct {
	entry otelstream.Entry
	span  otelstream.Span
	err   error
}

type spanTree struct {
	maxEntries        int
	items             []spanTreeItem
	byID              map[string]otelstream.Span
	entryBySpanID     map[string]otelstream.Entry
	traceStarts       map[string]int64
	lastArrivedSpanID string
}

type spanTreeRenderer interface {
	renderSpanLine(otelstream.Span, int64, string) string
	predicatesFor(otelstream.Span, string) []predicate
	renderPredicateLine(predicate) string
	renderErrorLine(string, string) string
}

func newSpanTree(maxEntries int) spanTree {
	return spanTree{
		maxEntries:    maxEntries,
		byID:          map[string]otelstream.Span{},
		entryBySpanID: map[string]otelstream.Entry{},
		traceStarts:   map[string]int64{},
	}
}

// absorb registers a freshly-arrived item, evicting the oldest entry from the
// ring buffer if needed. Late-arriving parents are handled when lines are
// materialized, so insertion order does not need to be topological.
func (t *spanTree) absorb(item spanTreeItem) {
	t.items = append(t.items, item)
	if t.maxEntries > 0 && len(t.items) > t.maxEntries {
		drop := len(t.items) - t.maxEntries
		for _, it := range t.items[:drop] {
			if it.err == nil {
				delete(t.byID, it.span.SpanID)
				delete(t.entryBySpanID, it.span.SpanID)
			}
		}
		t.items = t.items[drop:]
	}

	if item.err == nil {
		s := item.span
		t.byID[s.SpanID] = s
		t.entryBySpanID[s.SpanID] = item.entry
		if start, ok := t.traceStarts[s.TraceID]; !ok || s.StartUnixNano < start {
			t.traceStarts[s.TraceID] = s.StartUnixNano
		}
		t.lastArrivedSpanID = s.SpanID
	}
}

func (t spanTree) itemForSpanID(spanID string) (spanTreeItem, bool) {
	span, ok := t.byID[spanID]
	if !ok {
		return spanTreeItem{}, false
	}
	return spanTreeItem{entry: t.entryBySpanID[spanID], span: span}, true
}

// renderLines walks the current span buffer trace by trace, rendering each
// trace's tree of spans sorted by start time. Spans whose parent is no longer
// in the buffer are treated as roots of their trace, so eviction never strands
// children invisibly.
func (t spanTree) renderLines(renderer spanTreeRenderer) []renderedLine {
	lines := []renderedLine{}

	if len(t.byID) == 0 {
		// Surface decoder errors that arrived since the last span. We render
		// them as their own pseudo-section so they're visible even before any
		// real spans have shown up.
		for _, it := range t.items {
			if it.err != nil {
				lines = append(lines, renderedLine{
					kind:     lineKindError,
					depth:    0,
					rendered: renderer.renderErrorLine(it.entry.ID, it.err.Error()),
				})
			}
		}
		return lines
	}

	byTrace := map[string][]otelstream.Span{}
	for _, s := range t.byID {
		byTrace[s.TraceID] = append(byTrace[s.TraceID], s)
	}

	traceIDs := make([]string, 0, len(byTrace))
	for traceID := range byTrace {
		traceIDs = append(traceIDs, traceID)
	}
	sort.Slice(traceIDs, func(i, j int) bool {
		return t.traceStarts[traceIDs[i]] < t.traceStarts[traceIDs[j]]
	})

	for _, traceID := range traceIDs {
		spans := byTrace[traceID]
		children := map[string][]otelstream.Span{}
		for _, s := range spans {
			parent := s.ParentSpanID
			if parent != "" {
				if _, ok := t.byID[parent]; !ok {
					parent = "" // orphan: treat as a root within this trace
				}
			}
			children[parent] = append(children[parent], s)
		}
		for parent := range children {
			sortSpans(children[parent])
		}
		lines = t.emitChildren(lines, renderer, children, "", 0)
	}

	return lines
}

func (t spanTree) emitChildren(lines []renderedLine, renderer spanTreeRenderer, children map[string][]otelstream.Span, parent string, depth int) []renderedLine {
	for _, s := range children[parent] {
		lines = append(lines, renderedLine{
			kind:     lineKindSpan,
			depth:    depth,
			rendered: renderer.renderSpanLine(s, t.traceStarts[s.TraceID], t.entryBySpanID[s.SpanID].ID),
			spanID:   s.SpanID,
		})
		for _, p := range renderer.predicatesFor(s, t.entryBySpanID[s.SpanID].ID) {
			lines = append(lines, renderedLine{
				kind:     lineKindPredicate,
				depth:    depth + 1,
				rendered: renderer.renderPredicateLine(p),
			})
		}
		lines = t.emitChildren(lines, renderer, children, s.SpanID, depth+1)
	}
	return lines
}

func sortSpans(spans []otelstream.Span) {
	sort.Slice(spans, func(i, j int) bool {
		if spans[i].StartUnixNano != spans[j].StartUnixNano {
			return spans[i].StartUnixNano < spans[j].StartUnixNano
		}
		return spans[i].SpanID < spans[j].SpanID
	})
}

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
func predicatesOf(s otelstream.Span, entryID string) []predicate {
	out := []predicate{{verb: "entry", value: displayEntryID(entryID), valueFor: "info"}}
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
	case "sheaf.statement_bytes":
		return predicate{verb: "statement size", value: value + " bytes", valueFor: "info"}
	case "sheaf.response_bytes":
		return predicate{verb: "response size", value: value + " bytes", valueFor: "info"}
	case "sheaf.response_content_type":
		return predicate{verb: "decoded", value: value, valueFor: "info"}
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
