package main

import (
	"context"
	"fmt"
	"sort"
	"strings"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/mbrock/sheaf/tools/otel-tail/internal/otelstream"
)

const (
	maxTUIEntries = 1000
	indentStep    = 2
)

type tuiItem struct {
	entry otelstream.Entry
	span  otelstream.Span
	err   error
}

type tuiEntryMsg tuiItem
type tuiReadErrorMsg string
type tuiTailStoppedMsg struct{ err error }

type tuiModel struct {
	ctx      context.Context
	cancel   context.CancelFunc
	entries  <-chan tuiItem
	readErrs <-chan error
	done     <-chan error

	// Storage. items is the arrival-ordered ring buffer; byID indexes it
	// for parent lookup; traceStarts remembers each trace's earliest
	// observed StartUnixNano for T+offset display.
	items       []tuiItem
	byID        map[string]otelstream.Span
	traceStarts map[string]int64

	// Materialized view. Recomputed from byID on every change so that
	// late-arriving parents naturally slot under the right ancestors.
	lines []renderedLine

	// Selection is sticky by span id: when the tree rebuilds, we relocate
	// the cursor onto the same span wherever it landed. autoTail follows
	// the most recently arrived span.
	selectedSpanID    string
	lastArrivedSpanID string
	selected          int
	offset            int

	width    int
	height   int
	autoTail bool
	status   string
	fatal    error
	styles   tuiStyles
}

func runTUI(ctx context.Context, tailer otelstream.RedisTailer, opts otelstream.TailOptions) error {
	tuiCtx, cancel := context.WithCancel(ctx)
	entries := make(chan tuiItem, 100)
	readErrs := make(chan error, 10)
	done := make(chan error, 1)

	tailer.OnReadError = func(err error) {
		select {
		case readErrs <- err:
		default:
		}
	}

	go func() {
		defer close(done)
		done <- tailer.Tail(tuiCtx, opts, func(entry otelstream.Entry) error {
			item := tuiItem{entry: entry}
			span, err := otelstream.DecodeSpan(entry.Raw)
			if err != nil {
				item.err = err
			} else {
				item.span = span
			}

			select {
			case entries <- item:
				return nil
			case <-tuiCtx.Done():
				return nil
			}
		})
	}()

	model := tuiModel{
		ctx:         tuiCtx,
		cancel:      cancel,
		entries:     entries,
		readErrs:    readErrs,
		done:        done,
		byID:        map[string]otelstream.Span{},
		traceStarts: map[string]int64{},
		selected:    -1,
		width:       80,
		height:      24,
		autoTail:    true,
		status:      "waiting for spans...",
		styles:      newTUIStyles(true),
	}
	program := tea.NewProgram(model)
	_, err := program.Run()
	cancel()
	return err
}

func (m tuiModel) Init() tea.Cmd {
	return tea.Batch(
		tea.RequestBackgroundColor,
		waitForTUIEntry(m.entries),
		waitForTUIReadError(m.readErrs),
		waitForTUITailDone(m.done),
	)
}

func (m tuiModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.String() {
		case "ctrl+c", "q":
			m.cancel()
			return m, tea.Quit
		case "up", "k":
			m.jumpToSpan(-1)
		case "down", "j":
			m.jumpToSpan(1)
		case "pgup":
			m.pageBy(-m.listHeight())
		case "pgdown":
			m.pageBy(m.listHeight())
		case "home":
			m.gotoLine(0, false)
		case "end", "G":
			m.followTail()
		}
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		m.ensureSelectedVisible()
	case tea.BackgroundColorMsg:
		m.styles = newTUIStyles(msg.IsDark())
		m.rebuildLines()
		m.refreshSelection()
	case tuiEntryMsg:
		m.absorb(tuiItem(msg))
		return m, waitForTUIEntry(m.entries)
	case tuiReadErrorMsg:
		m.status = "read error: " + string(msg)
		return m, waitForTUIReadError(m.readErrs)
	case tuiTailStoppedMsg:
		if msg.err != nil && m.ctx.Err() == nil {
			m.fatal = msg.err
			m.status = "tail stopped: " + msg.err.Error()
		}
		return m, nil
	}
	return m, nil
}

// absorb registers a freshly-arrived item, evicting the oldest entry from
// the ring buffer if needed, and triggers a tree rebuild + cursor refresh.
func (m *tuiModel) absorb(item tuiItem) {
	m.items = append(m.items, item)
	if len(m.items) > maxTUIEntries {
		drop := len(m.items) - maxTUIEntries
		for _, it := range m.items[:drop] {
			if it.err == nil {
				delete(m.byID, it.span.SpanID)
			}
		}
		m.items = m.items[drop:]
	}

	if item.err == nil {
		s := item.span
		m.byID[s.SpanID] = s
		if t, ok := m.traceStarts[s.TraceID]; !ok || s.StartUnixNano < t {
			m.traceStarts[s.TraceID] = s.StartUnixNano
		}
		m.lastArrivedSpanID = s.SpanID
	}

	m.rebuildLines()
	m.refreshSelection()
}

// rebuildLines walks the current span buffer trace by trace, rendering
// each trace's tree of spans (sorted by start time) into the lines slice.
// Spans whose parent is no longer in the buffer are treated as roots of
// their trace, so eviction never strands children invisibly.
func (m *tuiModel) rebuildLines() {
	m.lines = m.lines[:0]

	if len(m.byID) == 0 {
		// Surface decoder errors that arrived since the last span. We render
		// them as their own pseudo-section so they're visible even before any
		// real spans have shown up.
		for _, it := range m.items {
			if it.err != nil {
				m.lines = append(m.lines, renderedLine{
					kind:     lineKindError,
					depth:    0,
					rendered: m.renderErrorLine(it.entry.ID, it.err.Error()),
				})
			}
		}
		return
	}

	byTrace := map[string][]otelstream.Span{}
	for _, s := range m.byID {
		byTrace[s.TraceID] = append(byTrace[s.TraceID], s)
	}

	traceIDs := make([]string, 0, len(byTrace))
	for t := range byTrace {
		traceIDs = append(traceIDs, t)
	}
	sort.Slice(traceIDs, func(i, j int) bool {
		return m.traceStarts[traceIDs[i]] < m.traceStarts[traceIDs[j]]
	})

	for _, traceID := range traceIDs {
		spans := byTrace[traceID]
		children := map[string][]otelstream.Span{}
		for _, s := range spans {
			parent := s.ParentSpanID
			if parent != "" {
				if _, ok := m.byID[parent]; !ok {
					parent = "" // orphan: treat as a root within this trace
				}
			}
			children[parent] = append(children[parent], s)
		}
		for k := range children {
			sortSpans(children[k])
		}
		m.emitChildren(children, "", 0)
	}
}

func (m *tuiModel) emitChildren(children map[string][]otelstream.Span, parent string, depth int) {
	for _, s := range children[parent] {
		m.lines = append(m.lines, renderedLine{
			kind:     lineKindSpan,
			depth:    depth,
			rendered: m.renderSpanLine(s),
			spanID:   s.SpanID,
		})
		for _, p := range predicatesOf(s) {
			m.lines = append(m.lines, renderedLine{
				kind:     lineKindPredicate,
				depth:    depth + 1,
				rendered: m.renderPredicateLine(p),
			})
		}
		m.emitChildren(children, s.SpanID, depth+1)
	}
}

func sortSpans(spans []otelstream.Span) {
	sort.Slice(spans, func(i, j int) bool {
		if spans[i].StartUnixNano != spans[j].StartUnixNano {
			return spans[i].StartUnixNano < spans[j].StartUnixNano
		}
		return spans[i].SpanID < spans[j].SpanID
	})
}

// refreshSelection relocates the cursor after a tree rebuild. In autoTail
// mode it tracks the most recently arrived span; otherwise it follows the
// previously selected span by id, falling back to the nearest line if the
// span has been evicted.
func (m *tuiModel) refreshSelection() {
	if len(m.lines) == 0 {
		m.selected = -1
		m.offset = 0
		return
	}

	target := m.selectedSpanID
	if m.autoTail {
		target = m.lastArrivedSpanID
	}

	if target != "" {
		for i, l := range m.lines {
			if l.kind == lineKindSpan && l.spanID == target {
				m.selected = i
				m.selectedSpanID = target
				m.ensureSelectedVisible()
				return
			}
		}
	}

	// Selected span is gone (evicted or never existed). Clamp.
	if m.selected < 0 || m.selected >= len(m.lines) {
		m.selected = len(m.lines) - 1
	}
	m.selectedSpanID = m.spanIDForLine(m.selected)
	m.ensureSelectedVisible()
}

// spanIDForLine returns the span id associated with the line at idx, or
// the nearest span line above it if idx is on a predicate.
func (m tuiModel) spanIDForLine(idx int) string {
	for i := idx; i >= 0; i-- {
		if i < len(m.lines) && m.lines[i].kind == lineKindSpan {
			return m.lines[i].spanID
		}
	}
	return ""
}

// pageBy shifts the cursor by `delta` raw lines and then snaps to the
// nearest span line (preferring the one in the direction of movement).
// Used for pgup/pgdown so big jumps still land on a real heading.
func (m *tuiModel) pageBy(delta int) {
	if len(m.lines) == 0 {
		return
	}
	target := m.selected + delta
	if target < 0 {
		target = 0
	}
	if target >= len(m.lines) {
		target = len(m.lines) - 1
	}
	step := 1
	if delta < 0 {
		step = -1
	}
	for i := target; i >= 0 && i < len(m.lines); i += step {
		if m.lines[i].kind == lineKindSpan {
			m.gotoLine(i, false)
			return
		}
	}
	for i := target; i >= 0 && i < len(m.lines); i -= step {
		if m.lines[i].kind == lineKindSpan {
			m.gotoLine(i, false)
			return
		}
	}
}

func (m *tuiModel) gotoLine(idx int, autoTail bool) {
	if idx < 0 {
		idx = 0
	}
	if idx >= len(m.lines) {
		idx = len(m.lines) - 1
	}
	m.selected = idx
	if id := m.spanIDForLine(idx); id != "" {
		m.selectedSpanID = id
	}
	m.autoTail = autoTail || (m.lastArrivedSpanID != "" && m.selectedSpanID == m.lastArrivedSpanID)
	m.ensureSelectedVisible()
}

func (m *tuiModel) jumpToSpan(dir int) {
	if len(m.lines) == 0 {
		return
	}
	i := m.selected + dir
	for i >= 0 && i < len(m.lines) {
		if m.lines[i].kind == lineKindSpan {
			m.gotoLine(i, false)
			return
		}
		i += dir
	}
}

func (m *tuiModel) followTail() {
	m.autoTail = true
	if m.lastArrivedSpanID != "" {
		for i, l := range m.lines {
			if l.kind == lineKindSpan && l.spanID == m.lastArrivedSpanID {
				m.selected = i
				m.selectedSpanID = m.lastArrivedSpanID
				m.ensureSelectedVisible()
				return
			}
		}
	}
	if len(m.lines) > 0 {
		m.selected = len(m.lines) - 1
		m.selectedSpanID = m.spanIDForLine(m.selected)
	}
	m.ensureSelectedVisible()
}

func (m tuiModel) View() tea.View {
	view := tea.NewView(m.viewString())
	view.AltScreen = true
	return view
}

func (m tuiModel) viewString() string {
	if m.width == 0 {
		return "starting otel...\n"
	}

	barStart, barEnd := m.spanBarRange()

	var b strings.Builder
	listH := m.listHeight()
	visible := m.visibleLines()
	for i := 0; i < visible; i++ {
		if i > 0 {
			b.WriteByte('\n')
		}
		index := m.offset + i
		mark := barNone
		if index == m.selected {
			mark = barPrimary
		} else if index >= barStart && index < barEnd {
			mark = barSecondary
		}
		b.WriteString(m.renderViewLine(index, mark))
	}
	for i := visible; i < listH; i++ {
		if i > 0 {
			b.WriteByte('\n')
		}
		b.WriteString(m.padRow(""))
	}
	return b.String()
}

// spanBarRange returns the half-open [start, end) range that the entire
// selection bar covers: the selected span itself plus every descendant
// (predicates, nested children, and their predicates, recursively). Since
// rebuildLines emits in DFS order, the subtree is always contiguous.
func (m tuiModel) spanBarRange() (int, int) {
	if m.selected < 0 || m.selected >= len(m.lines) {
		return -1, -1
	}
	start := m.selected
	if m.lines[start].kind != lineKindSpan {
		return start, start + 1
	}
	d := m.lines[start].depth
	end := start + 1
	for end < len(m.lines) && m.lines[end].depth > d {
		end++
	}
	return start, end
}

type barMark int

const (
	barNone barMark = iota
	barPrimary
	barSecondary
)

func (m tuiModel) renderViewLine(idx int, mark barMark) string {
	if idx < 0 || idx >= len(m.lines) {
		return m.padRow("")
	}
	line := m.lines[idx]

	indent := strings.Repeat(" ", indentStep*line.depth)
	prefix := "  "
	switch mark {
	case barPrimary:
		prefix = m.styles.cursor.Render("▌ ")
	case barSecondary:
		prefix = m.styles.cursorTrail.Render("│ ")
	}
	return m.padRow(prefix + indent + line.rendered)
}

func (m tuiModel) padRow(row string) string {
	w := lipgloss.Width(row)
	if w >= m.width {
		return lipgloss.NewStyle().MaxWidth(m.width).Render(row)
	}
	return row + strings.Repeat(" ", m.width-w)
}

func (m tuiModel) renderSpanLine(s otelstream.Span) string {
	st := m.styles
	body := st.spanMark.Render("*") + " " + st.spanName.Render(s.Name)
	body += "  " + st.spanDurationStyle(s.DurationUs).Render(formatDuration(s.DurationUs))
	if off := formatOffset(m.traceStarts[s.TraceID], s.StartUnixNano); off != "" {
		body += "  " + st.spanMeta.Render(off)
	}
	if s.Status != nil && s.Status.Code == "error" {
		body += "  " + st.errorMark.Render("✗")
	}
	return body
}

func (m tuiModel) renderPredicateLine(p predicate) string {
	st := m.styles
	body := st.predMark.Render("¶") + " " + st.predVerb.Render(p.verb)
	if p.value != "" {
		body += " " + st.valueStyle(p.valueFor).Render(p.value)
	}
	return body
}

func (m tuiModel) renderErrorLine(id, msg string) string {
	st := m.styles
	return st.errorMark.Render("!") + " " + st.errorRow.Render(fmt.Sprintf("%s  decode error: %s", id, msg))
}

func waitForTUIEntry(entries <-chan tuiItem) tea.Cmd {
	return func() tea.Msg {
		item, ok := <-entries
		if !ok {
			return tuiTailStoppedMsg{}
		}
		return tuiEntryMsg(item)
	}
}

func waitForTUIReadError(readErrs <-chan error) tea.Cmd {
	return func() tea.Msg {
		err, ok := <-readErrs
		if !ok {
			return nil
		}
		return tuiReadErrorMsg(err.Error())
	}
}

func waitForTUITailDone(done <-chan error) tea.Cmd {
	return func() tea.Msg {
		err, ok := <-done
		if !ok {
			return tuiTailStoppedMsg{}
		}
		return tuiTailStoppedMsg{err: err}
	}
}

func (m *tuiModel) ensureSelectedVisible() {
	if len(m.lines) == 0 || m.selected < 0 {
		m.offset = 0
		return
	}
	height := m.visibleLines()
	if height <= 0 {
		m.offset = 0
		return
	}
	if m.selected < m.offset {
		m.offset = m.selected
	}
	if m.selected >= m.offset+height {
		m.offset = m.selected - height + 1
	}
	maxOffset := len(m.lines) - height
	if maxOffset < 0 {
		maxOffset = 0
	}
	if m.offset > maxOffset {
		m.offset = maxOffset
	}
}

func (m tuiModel) visibleLines() int {
	height := m.listHeight()
	if height > len(m.lines) {
		height = len(m.lines)
	}
	if height < 0 {
		return 0
	}
	return height
}

func (m tuiModel) listHeight() int {
	if m.height < 1 {
		return 1
	}
	return m.height
}
