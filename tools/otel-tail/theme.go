// Theme port of Linen Glow's OKLCH + semantic-token paradigm.
//
// Linen Glow is defined declaratively in Prolog: a small set of named hues,
// uniform chroma, lightness levels, and named alphas, mapped onto semantic
// roles (error, warning, info, added, focus, selection, ...). This file is
// the same idea expressed in Go: a tiny resolver that takes a token like
// fgError or bgSelection and returns an OKLCH color, with light/dark mode
// handled by inverting lightness around 50.
package main

import "image/color"

// Hue names mirror theme.pl. Values are degrees on the OKLCH wheel.
var hues = map[string]float64{
	"coral":   25,
	"orange":  55,
	"gold":    85,
	"green":   150,
	"aqua":    175,
	"cyan":    195,
	"sky":     235,
	"blue":    250,
	"purple":  300,
	"magenta": 320,
	"neutral": 85,
	"gray":    0,
}

// Named alphas, also from theme.pl.
const (
	alphaHint   = 0.15
	alphaSoft   = 0.30
	alphaMedium = 0.45
	alphaStrong = 0.60
)

// face is a kind of token: foreground or background. Linen Glow treats fg
// and bg roles independently because they use different lightness defaults
// and alphas.
type face int

const (
	faceFg face = iota
	faceBg
)

// role names a semantic slot. Foreground and background roles share names
// but resolve through `face`.
type role string

const (
	roleText      role = "text"
	roleMuted     role = "muted"
	roleSubtle    role = "subtle"
	roleError     role = "error"
	roleWarning   role = "warning"
	roleInfo      role = "info"
	roleAdded     role = "added"
	roleModified  role = "modified"
	roleDeleted   role = "deleted"
	roleConflict  role = "conflict"
	roleFocus     role = "focus"
	roleMatch     role = "match"
	roleBracket   role = "bracket"
	roleSelection role = "selection"
	roleHighlight role = "highlight"

	roleBase    role = "base"
	roleSurface role = "surface"
	roleRaised  role = "raised"
)

// hueOf returns the named hue for (face, role). Backgrounds that aren't
// listed fall back to gray surfaces.
func hueOf(f face, r role) string {
	if f == faceFg {
		switch r {
		case roleText, roleMuted, roleSubtle:
			return "neutral"
		case roleError, roleDeleted:
			return "coral"
		case roleWarning, roleModified, roleFocus, roleMatch:
			return "gold"
		case roleInfo, roleSelection, roleHighlight:
			return "blue"
		case roleAdded, roleBracket:
			return "green"
		case roleConflict:
			return "magenta"
		case roleBase, roleSurface, roleRaised:
			return "gray"
		}
	} else {
		switch r {
		case roleSelection, roleHighlight:
			return "blue"
		case roleMatch, roleFocus:
			return "gold"
		case roleBracket:
			return "green"
		case roleError:
			return "coral"
		case roleBase, roleSurface, roleRaised:
			return "gray"
		}
	}
	return "neutral"
}

// lightnessOf returns the dark-mode lightness (in [0,100]). Light mode
// inverts via 100 - L, matching theme.pl.
func lightnessOf(f face, r role) float64 {
	if f == faceFg {
		switch r {
		case roleText:
			return 85
		case roleMuted:
			return 45
		case roleSubtle:
			return 70
		}
	} else {
		switch r {
		case roleBase:
			return 0
		case roleSurface:
			return 7
		case roleRaised:
			return 14
		}
	}
	return 80
}

// alphaOf returns the alpha for backgrounds that should tint rather than
// fill. Foregrounds and unlisted backgrounds are opaque.
func alphaOf(f face, r role) float64 {
	if f != faceBg {
		return 1
	}
	switch r {
	case roleSelection:
		return alphaSoft
	case roleHighlight, roleBracket:
		return alphaHint
	case roleMatch:
		return alphaMedium
	}
	return 1
}

// chromaOf mirrors theme.pl: gray is achromatic, neutral is barely
// off-white, everything else uses the saturated default.
func chromaOf(hue string) float64 {
	switch hue {
	case "gray":
		return 0
	case "neutral":
		return 0.04
	default:
		return 0.20
	}
}

// resolve returns the OKLCH color for a (face, role) under the given mode.
func resolve(isDark bool, f face, r role) oklch {
	hue := hueOf(f, r)
	l := lightnessOf(f, r)
	if !isDark {
		l = 100 - l
	}
	return oklch{
		L: l,
		C: chromaOf(hue),
		H: hues[hue],
		A: alphaOf(f, r),
	}
}

// rgbaOf is the common case: resolve a token to a flat sRGB color. For
// alpha-tinted background tokens, the result is flattened over bg(base) so
// the terminal sees a single solid color.
func rgbaOf(isDark bool, f face, r role) color.RGBA {
	c := resolve(isDark, f, r)
	if c.A >= 1 {
		return c.toRGBA()
	}
	return c.flattenOver(resolve(isDark, faceBg, roleBase).toRGBA())
}

// hueColor returns a saturated foreground color at the standard fg
// lightness. Useful when something doesn't have a semantic role (e.g.
// span-kind badges) but should still draw from the named palette.
func hueColor(isDark bool, hue string) color.RGBA {
	l := 80.0
	if !isDark {
		l = 20
	}
	return oklch{L: l, C: chromaOf(hue), H: hues[hue], A: 1}.toRGBA()
}
