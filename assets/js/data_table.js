import {measureNaturalWidth, prepareWithSegments} from "@chenglou/pretext"

const SAFETY_PX = 2

export const DataTable = {
  mounted() {
    this.raf = null
    this.cells = new Set()
    this.measureCache = new Map()
    this.resizeObserver = new ResizeObserver(() => this.scheduleMeasure())
    this.fontsReady = () => {
      this.measureCache.clear()
      this.scheduleMeasure()
    }

    if (document.fonts) {
      document.fonts.ready.then(this.fontsReady)
      document.fonts.addEventListener("loadingdone", this.fontsReady)
    }

    this.sync()
  },
  updated() {
    this.sync()
  },
  destroyed() {
    if (this.raf !== null) cancelAnimationFrame(this.raf)
    this.resizeObserver.disconnect()
    if (document.fonts) {
      document.fonts.removeEventListener("loadingdone", this.fontsReady)
    }
  },
  sync() {
    const seen = new Set(this.el.querySelectorAll("[data-table-heading-cell]"))

    for (const cell of seen) {
      if (this.cells.has(cell)) continue
      this.cells.add(cell)
      this.resizeObserver.observe(cell)
    }

    for (const cell of this.cells) {
      if (seen.has(cell)) continue
      this.resizeObserver.unobserve(cell)
      this.cells.delete(cell)
    }

    this.scheduleMeasure()
  },
  scheduleMeasure() {
    if (this.raf !== null) return
    this.raf = requestAnimationFrame(() => {
      this.raf = null
      this.measureHeadings()
    })
  },
  measureHeadings() {
    let hasRotatedHeading = false

    for (const label of this.el.querySelectorAll("[data-table-heading-label]")) {
      const cell = label.closest("[data-table-heading-cell]")
      if (!cell) continue

      const availableWidth = cell.getBoundingClientRect().width
      if (availableWidth <= 0) continue

      const labelWidth = this.headingWidth(label)
      const rotate = labelWidth + SAFETY_PX > availableWidth
      label.dataset.rotated = rotate ? "true" : "false"
      cell.dataset.rotated = rotate ? "true" : "false"
      hasRotatedHeading = hasRotatedHeading || rotate
    }

    this.el.dataset.rotatedHeadings = hasRotatedHeading ? "true" : "false"
  },
  headingWidth(label) {
    const style = getComputedStyle(label)
    const font = fontShorthand(style)
    const letterSpacing = parseCssPixels(style.letterSpacing)
    const text = label.dataset.heading ?? label.textContent?.trim() ?? ""
    const cacheKey = `${font}|${letterSpacing}|${text}`
    let width = this.measureCache.get(cacheKey)

    if (width === undefined) {
      const prepared = prepareWithSegments(text, font, {letterSpacing})
      width = measureNaturalWidth(prepared)
      this.measureCache.set(cacheKey, width)
    }

    return width + parseCssPixels(style.paddingLeft) + parseCssPixels(style.paddingRight)
  },
}

function fontShorthand(style) {
  return `${style.fontStyle} ${style.fontVariant} ${style.fontWeight} ${style.fontSize} ${style.fontFamily}`
}

function parseCssPixels(value) {
  if (!value || value === "normal") return 0
  const parsed = Number.parseFloat(value)
  return Number.isFinite(parsed) ? parsed : 0
}
