import {clearCache, prepareWithSegments} from "@chenglou/pretext"

const HUGE_BADNESS = 1e8
const SOFT_HYPHEN = "\u00AD"
const SHORT_LINE_RATIO = 0.6
const MIN_SPACE_RATIO = 0.9
const RIVER_THRESHOLD = 1.5
const WRAP_FRAME_BUDGET_MS = 8
const TEXT_BOUNDARY_TAGS = new Set([
  "ADDRESS",
  "ARTICLE",
  "ASIDE",
  "BLOCKQUOTE",
  "BR",
  "DD",
  "DIV",
  "DL",
  "DT",
  "FIGCAPTION",
  "FIGURE",
  "FOOTER",
  "H1",
  "H2",
  "H3",
  "H4",
  "H5",
  "H6",
  "HEADER",
  "LI",
  "MAIN",
  "NAV",
  "OL",
  "P",
  "SECTION",
  "TABLE",
  "TBODY",
  "TD",
  "TFOOT",
  "TH",
  "THEAD",
  "TR",
  "UL",
])

const states = new WeakMap()
const observed = new Set()
const pending = new Set()
const loadedFonts = new Set()
const fontLoadPromises = new Map()
const fontWaitTargets = new Map()
const resizeObserver = new ResizeObserver(entries => {
  for (const entry of entries) schedule(entry.target)
})

let raf = null
let fontEpoch = 0

export const PretextParagraph = {
  mounted() {
    refreshParagraph(this.el)
  },
  updated() {
    refreshParagraph(this.el)
  },
  destroyed() {
    resizeObserver.unobserve(this.el)
    states.delete(this.el)
    observed.delete(this.el)
    pending.delete(this.el)
    forgetFontWaitTarget(this.el)
  },
}

function schedule(target) {
  pending.add(target)
  schedulePending()
}

function schedulePending() {
  if (raf !== null) return

  raf = requestAnimationFrame(() => {
    raf = null
    const deadline = performance.now() + WRAP_FRAME_BUDGET_MS

    while (pending.size > 0) {
      const target = pending.values().next().value
      pending.delete(target)
      wrapParagraph(target)

      if (pending.size > 0 && performance.now() >= deadline) {
        schedulePending()
        return
      }
    }
  })
}

function refreshParagraph(target) {
  if (!observed.has(target)) {
    observed.add(target)
    resizeObserver.observe(target)
  }

  let state = states.get(target)
  const previousText = state?.text
  const text = previousText ?? sourceText(target)
  rememberSourceText(target, text)

  if (state === undefined) {
    state = {text, key: null, fontLoadKey: null}
    states.set(target, state)
  } else {
    state.text = text
    if (previousText !== text) state.key = null
  }

  schedule(target)
}

function wrapParagraph(target) {
  if (!target.isConnected) return

  const width = target.getBoundingClientRect().width
  if (width <= 0) return

  const state = getState(target)
  const style = getComputedStyle(target)
  const font = fontShorthand(style)
  const lineHeight = lineHeightPx(style)
  const letterSpacing = lengthPx(style.letterSpacing) ?? 0

  if (fontNeedsLoading(font, state.text)) {
    waitForFont(target, font, state.text)
    return
  }

  const key = `${fontEpoch}\n${state.text}\n${font}\n${letterSpacing}\n${Math.round(width * 100) / 100}`
  if (state.key === key) return

  state.key = key

  const prepared = prepareWithSegments(state.text, font, {letterSpacing})
  const normalSpaceWidth = measureText(" ", font) + letterSpacing
  const hyphenWidth = measureText("-", font) + letterSpacing
  const lines = optimalLines(prepared, width, normalSpaceWidth, hyphenWidth)

  target.replaceChildren(...lines.map(line => lineElement(line, normalSpaceWidth, lineHeight)))
  target.dataset.pretextWrapped = "true"
  target.style.display = "block"
}

function getState(target) {
  let state = states.get(target)

  if (state === undefined) {
    state = {text: sourceText(target), key: null, fontLoadKey: null}
    rememberSourceText(target, state.text)
    states.set(target, state)
  }

  return state
}

function fontNeedsLoading(font, text) {
  if (document.fonts === undefined || loadedFonts.has(font)) return false
  if (fontLoadPromises.has(font)) return true

  try {
    if (document.fonts.check(font, fontLoadSample(text))) {
      loadedFonts.add(font)
      return false
    }

    return true
  } catch (_error) {
    return false
  }
}

function waitForFont(target, font, text) {
  const state = getState(target)
  if (state.fontLoadKey === font) return

  state.fontLoadKey = font
  let targets = fontWaitTargets.get(font)
  if (targets === undefined) {
    targets = new Set()
    fontWaitTargets.set(font, targets)
  }

  targets.add(target)
  ensureFontLoaded(font, text)
}

function ensureFontLoaded(font, text) {
  const existing = fontLoadPromises.get(font)
  if (existing !== undefined) return existing

  const promise = document.fonts.load(font, fontLoadSample(text))
    .catch(() => [])
    .finally(() => {
      loadedFonts.add(font)
      fontLoadPromises.delete(font)
      fontEpoch++
      clearCache()
      scheduleFontWaitTargets(font)
    })

  fontLoadPromises.set(font, promise)
  return promise
}

function scheduleFontWaitTargets(font) {
  const targets = fontWaitTargets.get(font)
  if (targets === undefined) return

  fontWaitTargets.delete(font)
  for (const target of targets) {
    const state = states.get(target)
    if (state?.fontLoadKey === font) state.fontLoadKey = null
    if (target.isConnected) pending.add(target)
  }

  schedulePending()
}

function forgetFontWaitTarget(target) {
  for (const [font, targets] of fontWaitTargets) {
    targets.delete(target)
    if (targets.size === 0) fontWaitTargets.delete(font)
  }
}

function fontLoadSample(text) {
  return text.replace(/\s+/g, " ").trim().slice(0, 128) || "A"
}

function optimalLines(prepared, maxWidth, normalSpaceWidth, hyphenWidth) {
  const segments = prepared.segments
  const widths = prepared.widths
  const segmentCount = segments.length
  if (segmentCount === 0) return []

  const breaks = [{segIndex: 0, kind: "start"}]
  for (let index = 0; index < segmentCount; index++) {
    const text = segments[index]
    if (text === SOFT_HYPHEN) {
      if (index + 1 < segmentCount) breaks.push({segIndex: index + 1, kind: "soft-hyphen"})
    } else if (isSpace(text) && index + 1 < segmentCount) {
      breaks.push({segIndex: index + 1, kind: "space"})
    }
  }
  breaks.push({segIndex: segmentCount, kind: "end"})

  const dp = Array(breaks.length).fill(Infinity)
  const previous = Array(breaks.length).fill(-1)
  dp[0] = 0

  for (let to = 1; to < breaks.length; to++) {
    const isLast = breaks[to].kind === "end"

    for (let from = to - 1; from >= 0; from--) {
      if (dp[from] === Infinity) continue

      const stats = lineStats(segments, widths, breaks, from, to, normalSpaceWidth, hyphenWidth)
      if (stats.naturalWidth > maxWidth * 2) break

      const total = dp[from] + badness(stats, maxWidth, normalSpaceWidth, isLast)
      if (total < dp[to]) {
        dp[to] = total
        previous[to] = from
      }
    }
  }

  const path = []
  for (let cursor = breaks.length - 1; cursor > 0;) {
    if (previous[cursor] === -1) {
      cursor--
      continue
    }
    path.push(cursor)
    cursor = previous[cursor]
  }
  path.reverse()

  const lines = []
  let from = 0
  for (const to of path) {
    lines.push(buildLine(prepared, breaks, from, to, maxWidth, normalSpaceWidth, hyphenWidth))
    from = to
  }
  return lines
}

function lineStats(segments, widths, breaks, fromBreak, toBreak, normalSpaceWidth, hyphenWidth) {
  const from = breaks[fromBreak].segIndex
  const to = breaks[toBreak].segIndex
  const softHyphen = breaks[toBreak].kind === "soft-hyphen"
  let wordWidth = 0
  let spaceCount = 0

  for (let index = from; index < to; index++) {
    const text = segments[index]
    if (text === SOFT_HYPHEN) continue
    if (isSpace(text)) {
      spaceCount++
    } else {
      wordWidth += widths[index]
    }
  }

  if (to > from && isSpace(segments[to - 1])) spaceCount--
  if (softHyphen) wordWidth += hyphenWidth

  return {
    wordWidth,
    spaceCount,
    naturalWidth: wordWidth + spaceCount * normalSpaceWidth,
    softHyphen,
  }
}

function badness(stats, maxWidth, normalSpaceWidth, isLast) {
  if (isLast) return stats.naturalWidth > maxWidth ? HUGE_BADNESS : 0

  if (stats.spaceCount <= 0) {
    const slack = maxWidth - stats.wordWidth
    return slack < 0 ? HUGE_BADNESS : slack * slack * 10
  }

  const justifiedSpace = (maxWidth - stats.wordWidth) / stats.spaceCount
  if (justifiedSpace < 0) return HUGE_BADNESS
  if (justifiedSpace < normalSpaceWidth * MIN_SPACE_RATIO) return HUGE_BADNESS

  const ratio = (justifiedSpace - normalSpaceWidth) / normalSpaceWidth
  const absRatio = Math.abs(ratio)
  const riverExcess = justifiedSpace / normalSpaceWidth - RIVER_THRESHOLD

  return (
    absRatio * absRatio * absRatio * 1000 +
    (riverExcess > 0 ? 5000 + riverExcess * riverExcess * 10000 : 0) +
    (stats.softHyphen ? 50 : 0)
  )
}

function buildLine(prepared, breaks, fromBreak, toBreak, maxWidth, normalSpaceWidth, hyphenWidth) {
  const from = breaks[fromBreak].segIndex
  const to = breaks[toBreak].segIndex
  const ending = breaks[toBreak].kind === "end" ? "end" : "wrap"
  const segments = []

  for (let index = from; index < to; index++) {
    const text = prepared.segments[index]
    if (text === SOFT_HYPHEN) continue
    segments.push({text, width: prepared.widths[index], space: isSpace(text)})
  }

  if (breaks[toBreak].kind === "soft-hyphen" && ending === "wrap") {
    segments.push({text: "-", width: hyphenWidth, space: false})
  }

  while (segments.length > 0 && segments[segments.length - 1].space) segments.pop()

  let wordWidth = 0
  let spaceCount = 0
  let naturalWidth = 0
  for (const segment of segments) {
    naturalWidth += segment.width
    if (segment.space) {
      spaceCount++
    } else {
      wordWidth += segment.width
    }
  }

  return {segments, text: segments.map(segment => segment.text).join(""), wordWidth, spaceCount, naturalWidth, maxWidth, normalSpaceWidth, ending}
}

function lineElement(line, normalSpaceWidth, lineHeight) {
  const element = document.createElement("span")
  element.dataset.pretextLine = "true"
  element.dataset.pretextText = line.text
  element.style.display = "block"
  element.style.lineHeight = `${lineHeight}px`
  element.style.whiteSpace = "nowrap"

  let spaceWidth = normalSpaceWidth
  if (shouldJustify(line)) {
    spaceWidth = Math.max(
      (line.maxWidth - line.wordWidth) / line.spaceCount,
      normalSpaceWidth * MIN_SPACE_RATIO
    )
  }

  for (const segment of line.segments) {
    element.appendChild(segmentElement(segment, spaceWidth))
  }

  return element
}

function segmentElement(segment, spaceWidth) {
  const element = document.createElement("span")
  element.textContent = segment.text
  element.style.display = "inline-block"
  element.style.whiteSpace = "pre"
  element.style.verticalAlign = "baseline"
  element.style.width = `${segment.space ? spaceWidth : segment.width}px`
  return element
}

function shouldJustify(line) {
  return line.ending !== "end" && line.spaceCount > 0 && line.naturalWidth >= line.maxWidth * SHORT_LINE_RATIO
}

function paragraphText(target) {
  return textFrom(target).replace(/\s+/g, " ").trim()
}

function sourceText(target) {
  return target.pretextSourceText ?? target.dataset.pretextSourceText ?? wrappedText(target) ?? paragraphText(target)
}

function rememberSourceText(target, text) {
  target.pretextSourceText = text
  target.dataset.pretextSourceText = text
}

function wrappedText(target) {
  if (target.dataset.pretextWrapped !== "true") return null

  const lines = Array.from(target.querySelectorAll(":scope > [data-pretext-line]"))
  if (lines.length === 0) return null

  return lines.map(line => line.dataset.pretextText ?? line.textContent ?? "").join(" ").replace(/\s+/g, " ").trim()
}

function textFrom(node) {
  if (node.nodeType === Node.TEXT_NODE) return node.nodeValue ?? ""
  if (node.nodeType !== Node.ELEMENT_NODE) return ""
  if (node.tagName === "SCRIPT" || node.tagName === "STYLE") return ""
  if (node.tagName === "BR") return " "

  const text = Array.from(node.childNodes).map(textFrom).join("")
  return TEXT_BOUNDARY_TAGS.has(node.tagName) ? ` ${text} ` : text
}

function isSpace(text) {
  return text.trim().length === 0
}

function fontShorthand(style) {
  return `${style.fontStyle} ${style.fontVariant} ${style.fontWeight} ${style.fontSize} ${style.fontFamily}`
}

function lineHeightPx(style) {
  const value = lengthPx(style.lineHeight)
  return value ?? (lengthPx(style.fontSize) ?? 16) * 1.2
}

function lengthPx(value) {
  if (value === "" || value === "normal") return null
  const parsed = Number.parseFloat(value)
  return Number.isFinite(parsed) ? parsed : null
}

const measuringContext = document.createElement("canvas").getContext("2d")

function measureText(text, font) {
  measuringContext.font = font
  return measuringContext.measureText(text).width
}
