package main

import (
	"image/color"

	"charm.land/lipgloss/v2"
)

// tuiStyles holds rendered lipgloss styles keyed by visual role. Every
// style derives from the Linen Glow paradigm in theme.go: pick a face (fg
// or bg) and a semantic role, and the resolver does the rest.
type tuiStyles struct {
	cursor      lipgloss.Style // primary indicator on the selected span line
	cursorTrail lipgloss.Style // dimmer indicator on descendant lines

	spanMark    lipgloss.Style // `*` glyph for span lines
	spanName    lipgloss.Style
	spanMeta    lipgloss.Style // dim trailing meta (T+offset)
	spanDurFast lipgloss.Style
	spanDurMed  lipgloss.Style
	spanDurSlow lipgloss.Style

	predMark  lipgloss.Style // `¶` glyph
	predVerb  lipgloss.Style
	predValue lipgloss.Style // default value style

	valueInfo    lipgloss.Style
	valueWarning lipgloss.Style
	valueError   lipgloss.Style
	valueMuted   lipgloss.Style

	errorRow  lipgloss.Style
	errorMark lipgloss.Style
}

func newTUIStyles(isDark bool) tuiStyles {
	fg := func(r role) color.Color { return rgbaOf(isDark, faceFg, r) }

	return tuiStyles{
		cursor:      lipgloss.NewStyle().Foreground(fg(roleFocus)).Bold(true),
		cursorTrail: lipgloss.NewStyle().Foreground(fg(roleSubtle)),

		// Span line: the * is the focus accent and the name pops as text.
		spanMark:    lipgloss.NewStyle().Foreground(fg(roleFocus)).Bold(true),
		spanName:    lipgloss.NewStyle().Foreground(fg(roleText)).Bold(true),
		spanMeta:    lipgloss.NewStyle().Foreground(fg(roleSubtle)),
		spanDurFast: lipgloss.NewStyle().Foreground(fg(roleMuted)),
		spanDurMed:  lipgloss.NewStyle().Foreground(fg(roleWarning)),
		spanDurSlow: lipgloss.NewStyle().Foreground(fg(roleError)).Bold(true),

		// Predicate line: muted verb leads, value pops in role color.
		predMark:  lipgloss.NewStyle().Foreground(fg(roleSubtle)),
		predVerb:  lipgloss.NewStyle().Foreground(fg(roleMuted)),
		predValue: lipgloss.NewStyle().Foreground(fg(roleText)),

		valueInfo:    lipgloss.NewStyle().Foreground(fg(roleInfo)),
		valueWarning: lipgloss.NewStyle().Foreground(fg(roleWarning)),
		valueError:   lipgloss.NewStyle().Foreground(fg(roleError)).Bold(true),
		valueMuted:   lipgloss.NewStyle().Foreground(fg(roleMuted)),

		errorRow:  lipgloss.NewStyle().Foreground(fg(roleError)),
		errorMark: lipgloss.NewStyle().Foreground(fg(roleError)).Bold(true),
	}
}

// spanDurationStyle picks a foreground that hints at how slow a span was:
// fast stays muted, slow pops in `error`. Thresholds are in microseconds.
func (s tuiStyles) spanDurationStyle(durationUs int64) lipgloss.Style {
	switch {
	case durationUs >= 500_000:
		return s.spanDurSlow
	case durationUs >= 50_000:
		return s.spanDurMed
	default:
		return s.spanDurFast
	}
}

// valueStyle maps a predicate's role hint to the color the value should
// render with. Empty hint or unknown roles fall back to the default text.
func (s tuiStyles) valueStyle(role string) lipgloss.Style {
	switch role {
	case "info":
		return s.valueInfo
	case "warning":
		return s.valueWarning
	case "error":
		return s.valueError
	case "muted":
		return s.valueMuted
	default:
		return s.predValue
	}
}
