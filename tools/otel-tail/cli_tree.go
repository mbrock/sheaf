package main

import (
	"encoding/json"
	"fmt"
	"io"
	"sort"
	"strings"

	"github.com/mbrock/sheaf/tools/otel-tail/internal/otelstream"
)

type cliTreeRenderer struct{}
type cliInspectRenderer struct{}

func renderSpanTree(out io.Writer, entries []otelstream.Entry, maxEntries int) error {
	tree := buildSpanTree(entries, maxEntries)
	return renderTreeLines(out, tree.renderLines(cliTreeRenderer{}))
}

func renderSpanTreeIDs(out io.Writer, entries []otelstream.Entry, ids []string, maxEntries int) error {
	tree := buildSpanTree(entries, maxEntries)
	matched := map[string]bool{}
	for _, id := range ids {
		for _, item := range tree.items {
			if item.err == nil && entryIDMatches(item.entry.ID, id) {
				matched[item.span.SpanID] = true
			}
		}
	}

	lines := tree.renderLines(cliInspectRenderer{})
	filtered := make([]renderedLine, 0, len(lines))
	for i := 0; i < len(lines); i++ {
		line := lines[i]
		if line.kind != lineKindSpan || !matched[line.spanID] {
			continue
		}
		rootDepth := line.depth
		filtered = append(filtered, line)
		for j := i + 1; j < len(lines) && lines[j].depth > rootDepth; j++ {
			filtered = append(filtered, renderedLine{
				kind:     lines[j].kind,
				depth:    lines[j].depth - rootDepth,
				rendered: lines[j].rendered,
				spanID:   lines[j].spanID,
			})
		}
	}
	return renderTreeLines(out, filtered)
}

func buildSpanTree(entries []otelstream.Entry, maxEntries int) spanTree {
	tree := newSpanTree(maxEntries)
	for _, entry := range entries {
		item := spanTreeItem{entry: entry}
		span, err := otelstream.DecodeSpan(entry.Raw)
		if err != nil {
			item.err = err
		} else {
			item.span = span
		}
		tree.absorb(item)
	}
	return tree
}

func renderTreeLines(out io.Writer, lines []renderedLine) error {
	for _, line := range lines {
		indent := strings.Repeat(" ", indentStep*line.depth)
		if _, err := fmt.Fprintln(out, indent+line.rendered); err != nil {
			return err
		}
	}
	return nil
}

func (cliTreeRenderer) renderSpanLine(s otelstream.Span, traceStart int64, entryID string) string {
	body := colorBlue + shortEntryID(entryID) + colorReset + " " + s.Name
	body += "  " + formatDuration(s.DurationUs)
	if off := formatOffset(traceStart, s.StartUnixNano); off != "" {
		body += "  " + colorDim + off + colorReset
	}
	if s.Status != nil && s.Status.Code == "error" {
		body += "  " + colorRed + "✗" + colorReset
	}
	return body
}

func (cliTreeRenderer) predicatesFor(s otelstream.Span, entryID string) []predicate {
	return predicatesOf(s, entryID)
}

func (cliTreeRenderer) renderPredicateLine(p predicate) string {
	body := colorDim + "¶ " + p.verb + colorReset
	if p.value != "" {
		body += " " + p.value
	}
	return body
}

func (cliTreeRenderer) renderErrorLine(id, msg string) string {
	return colorRed + "!" + colorReset + " " + fmt.Sprintf("%s  decode error: %s", id, msg)
}

func (cliInspectRenderer) renderSpanLine(s otelstream.Span, traceStart int64, entryID string) string {
	return cliTreeRenderer{}.renderSpanLine(s, traceStart, entryID)
}

func (cliInspectRenderer) renderPredicateLine(p predicate) string {
	return cliTreeRenderer{}.renderPredicateLine(p)
}

func (cliInspectRenderer) renderErrorLine(id, msg string) string {
	return cliTreeRenderer{}.renderErrorLine(id, msg)
}

func (cliInspectRenderer) predicatesFor(s otelstream.Span, entryID string) []predicate {
	out := []predicate{
		{verb: "entry", value: displayEntryID(entryID) + " (" + entryID + ")", valueFor: "info"},
		{verb: "trace", value: s.TraceID, valueFor: "info"},
		{verb: "span", value: s.SpanID, valueFor: "info"},
	}
	if s.ParentSpanID != "" {
		out = append(out, predicate{verb: "parent", value: s.ParentSpanID, valueFor: "info"})
	}
	out = append(out,
		predicate{verb: "kind", value: s.Kind, valueFor: "info"},
		predicate{verb: "started", value: fmt.Sprintf("%d", s.StartUnixNano), valueFor: "info"},
		predicate{verb: "ended", value: fmt.Sprintf("%d", s.EndUnixNano), valueFor: "info"},
	)
	if s.Status != nil {
		out = append(out, predicate{verb: "status", value: s.Status.Code + " " + s.Status.Message, valueFor: "error"})
	}
	appendMap := func(prefix string, m map[string]any) {
		keys := make([]string, 0, len(m))
		for key := range m {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		for _, key := range keys {
			out = append(out, predicate{verb: prefix + "." + key, value: formatInspectValue(m[key]), valueFor: "info"})
		}
	}
	appendMap("attr", s.Attributes)
	appendMap("scope", s.Scope)
	return out
}

func formatInspectValue(v any) string {
	if s, ok := v.(string); ok {
		return s
	}
	b, err := json.Marshal(v)
	if err != nil {
		return fmt.Sprint(v)
	}
	return string(b)
}
