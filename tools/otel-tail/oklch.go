package main

import (
	"image/color"
	"math"
)

// oklch is a color in the OKLCH space. L is in [0, 100] (percent, matching
// the Linen Glow theme's Prolog source); C is unbounded chroma (typical
// 0–0.4); H is in degrees; A is alpha in [0, 1].
type oklch struct {
	L, C, H, A float64
}

// toRGBA converts an OKLCH color to non-premultiplied sRGB. Values outside
// the sRGB gamut are simply clipped, which matches how browsers render
// `oklch()` in CSS.
func (o oklch) toRGBA() color.RGBA {
	L := o.L / 100
	hr := o.H * math.Pi / 180
	a := o.C * math.Cos(hr)
	b := o.C * math.Sin(hr)

	// OKLab -> linear sRGB via the canonical Björn Ottosson matrices.
	lp := L + 0.3963377774*a + 0.2158037573*b
	mp := L - 0.1055613458*a - 0.0638541728*b
	sp := L - 0.0894841775*a - 1.2914855480*b

	lc := lp * lp * lp
	mc := mp * mp * mp
	sc := sp * sp * sp

	rl := 4.0767416621*lc - 3.3077115913*mc + 0.2309699292*sc
	gl := -1.2684380046*lc + 2.6097574011*mc - 0.3413193965*sc
	bl := -0.0041960863*lc - 0.7034186147*mc + 1.7076147010*sc

	return color.RGBA{
		R: byteFromLinear(rl),
		G: byteFromLinear(gl),
		B: byteFromLinear(bl),
		A: clampByte(o.A * 255),
	}
}

// flattenOver alpha-composites o over background, returning a fully-opaque
// sRGB color. Terminals can't blend translucent backgrounds, so chrome tints
// (selection, highlight, match) need to be pre-flattened against the base.
func (o oklch) flattenOver(bg color.RGBA) color.RGBA {
	src := o.toRGBA()
	a := float64(src.A) / 255
	mix := func(s, d uint8) uint8 {
		return clampByte(float64(s)*a + float64(d)*(1-a))
	}
	return color.RGBA{
		R: mix(src.R, bg.R),
		G: mix(src.G, bg.G),
		B: mix(src.B, bg.B),
		A: 0xff,
	}
}

func srgbFromLinear(x float64) float64 {
	if x <= 0.0031308 {
		return 12.92 * x
	}
	return 1.055*math.Pow(x, 1.0/2.4) - 0.055
}

func byteFromLinear(x float64) uint8 {
	return clampByte(srgbFromLinear(x) * 255)
}

func clampByte(x float64) uint8 {
	v := math.Round(x)
	switch {
	case v < 0:
		return 0
	case v > 255:
		return 255
	default:
		return uint8(v)
	}
}
