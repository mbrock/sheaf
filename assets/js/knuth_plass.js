import {clearCache, prepareWithSegments} from "@chenglou/pretext"
import Hypher from "hypher"
import english from "hyphenation.en-us"

const SOFT_HYPHEN = "\u00AD"
const NON_BREAKING_HYPHEN = "\u2011"
const NBSP = "\u00A0"
const SAFETY_PX = 2
const FRAME_BUDGET_MS = 8
const HUGE_BADNESS = 1e10
const MAX_SPACE_RATIO = 1.7

const hypher = new Hypher(english)
const measuringContext = document.createElement("canvas").getContext("2d")

const allHooks = new Set()
let fontEpoch = 0

if (document.fonts) {
  document.fonts.addEventListener("loadingdone", () => {
    fontEpoch++
    clearCache()
    for (const hook of allHooks) hook.invalidateAll()
  })
}

export const KnuthPlass = {
  mounted() {
    this.scopes = new Map()
    this.pending = new Set()
    this.raf = null
    this.beforePrint = () => this.invalidateAll({immediate: true})
    this.afterPrint = () => this.invalidateAll()
    this.printMedia = window.matchMedia ? window.matchMedia("print") : null
    this.printMediaListener = event => {
      if (event.matches) this.invalidateAll({immediate: true})
      else this.invalidateAll()
    }
    this.observer = new ResizeObserver(entries => {
      for (const entry of entries) {
        const state = this.scopes.get(entry.target)
        if (!state) continue
        const w = entry.contentBoxSize?.[0]?.inlineSize ?? entry.contentRect.width
        if (w === state.width) continue
        state.width = w
        state.layoutKey = null
        this.pending.add(entry.target)
      }
      this.schedulePending()
    })
    allHooks.add(this)
    window.addEventListener("beforeprint", this.beforePrint)
    window.addEventListener("afterprint", this.afterPrint)
    if (this.printMedia) {
      if (this.printMedia.addEventListener) {
        this.printMedia.addEventListener("change", this.printMediaListener)
      } else if (this.printMedia.addListener) {
        this.printMedia.addListener(this.printMediaListener)
      }
    }
    this.sync()
  },
  updated() {
    this.sync()
  },
  destroyed() {
    this.observer.disconnect()
    allHooks.delete(this)
    window.removeEventListener("beforeprint", this.beforePrint)
    window.removeEventListener("afterprint", this.afterPrint)
    if (this.printMedia) {
      if (this.printMedia.removeEventListener) {
        this.printMedia.removeEventListener("change", this.printMediaListener)
      } else if (this.printMedia.removeListener) {
        this.printMedia.removeListener(this.printMediaListener)
      }
    }
    if (this.raf !== null) cancelAnimationFrame(this.raf)
  },
  sync() {
    const seen = new Set()
    for (const p of this.el.querySelectorAll("p")) {
      seen.add(p)
      if (this.scopes.has(p)) continue
      this.scopes.set(p, {
        snapshot: null,
        width: 0,
        font: null,
        styleEpoch: -1,
        prep: null,
        prepKey: null,
        layoutKey: null,
      })
      this.observer.observe(p)
      this.pending.add(p)
    }
    for (const p of this.scopes.keys()) {
      if (seen.has(p)) continue
      this.observer.unobserve(p)
      this.scopes.delete(p)
      this.pending.delete(p)
    }
    this.schedulePending()
  },
  invalidateAll(opts = {}) {
    for (const state of this.scopes.values()) {
      if (state.snapshot !== null) restoreSnapshot(state.snapshot)
      state.styleEpoch = -1
      state.prepKey = null
      state.layoutKey = null
    }
    for (const p of this.scopes.keys()) this.pending.add(p)
    if (opts.immediate) this.flushPending()
    else this.schedulePending()
  },
  schedulePending() {
    if (this.raf !== null || this.pending.size === 0) return
    this.raf = requestAnimationFrame(() => {
      this.raf = null
      const deadline = performance.now() + FRAME_BUDGET_MS
      while (this.pending.size > 0) {
        const scope = this.pending.values().next().value
        this.pending.delete(scope)
        this.wrap(scope)
        if (this.pending.size > 0 && performance.now() >= deadline) {
          this.schedulePending()
          return
        }
      }
    })
  },
  flushPending() {
    if (this.raf !== null) {
      cancelAnimationFrame(this.raf)
      this.raf = null
    }
    while (this.pending.size > 0) {
      const scope = this.pending.values().next().value
      this.pending.delete(scope)
      this.wrap(scope)
    }
  },
  wrap(scope) {
    if (!scope.isConnected) return
    if (unsupportedScope(scope)) return
    const state = this.scopes.get(scope)
    if (!state) return

    const currentWidth = scope.getBoundingClientRect().width
    if (currentWidth > 0 && currentWidth !== state.width) {
      state.width = currentWidth
      state.layoutKey = null
    }

    if (state.width <= 0) return

    if (state.snapshot === null) state.snapshot = snapshotTextNodes(scope)
    if (state.styleEpoch !== fontEpoch) {
      const style = getComputedStyle(scope)
      state.font = fontShorthand(style)
      state.styleEpoch = fontEpoch
    }

    const targetWidth = Math.max(0, state.width - SAFETY_PX)
    if (targetWidth <= 0) return

    const layoutKey = `${fontEpoch}|${state.font}|${Math.round(targetWidth * 100)}`
    if (state.layoutKey === layoutKey) return
    state.layoutKey = layoutKey

    const prepKey = `${fontEpoch}|${state.font}`
    if (state.prepKey !== prepKey) {
      refreshSnapshotMetrics(state.snapshot)
      state.prep = prepareScope(state.snapshot, state.font)
      state.prepKey = prepKey
    }

    if (state.prep === null) return
    applyLayout(state.snapshot, state.prep, targetWidth)
  },
}

function snapshotTextNodes(root) {
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT)
  const result = []
  let node
  while ((node = walker.nextNode())) {
    const parent = node.parentElement
    if (parent && (parent.tagName === "SCRIPT" || parent.tagName === "STYLE")) continue
    result.push({textNode: node, original: node.nodeValue ?? "", font: null})
  }
  return result
}

function restoreSnapshot(snapshot) {
  for (const entry of snapshot) {
    if (entry.textNode.isConnected) entry.textNode.nodeValue = entry.original
  }
}

function refreshSnapshotMetrics(snapshot) {
  for (const entry of snapshot) {
    const parent = entry.textNode.parentElement
    if (!parent) continue
    entry.font = fontShorthand(getComputedStyle(parent))
  }
}

function unsupportedScope(root) {
  return !!root.querySelector("br, code, pre, img, picture, svg, canvas, video, audio, iframe, math, table")
}

function prepareScope(snapshot, font) {
  const flat = []
  const flatOrigin = []
  let prevSpace = false
  for (let i = 0; i < snapshot.length; i++) {
    const entry = snapshot[i]
    if (!entry.textNode.isConnected) continue
    const text = entry.original
    for (let j = 0; j < text.length; j++) {
      const ch = text[j]
      if (ch === " " || ch === "\t" || ch === "\n" || ch === "\r" || ch === "\f") {
        if (!prevSpace) {
          flat.push(" ")
          flatOrigin.push(i)
          prevSpace = true
        }
      } else {
        flat.push(ch)
        flatOrigin.push(i)
        prevSpace = false
      }
    }
  }
  let start = 0
  while (start < flat.length && flat[start] === " ") start++
  let end = flat.length
  while (end > start && flat[end - 1] === " ") end--
  if (end <= start) return null
  const trimmed = flat.slice(start, end).join("")
  const trimmedOrigin = flatOrigin.slice(start, end)

  const hyphenated = hypher.hyphenateText(trimmed)
  const hyphOrigin = new Array(hyphenated.length)
  let fi = 0
  for (let hi = 0; hi < hyphenated.length; hi++) {
    const hc = hyphenated[hi]
    if (fi < trimmed.length && hc === trimmed[fi]) {
      hyphOrigin[hi] = trimmedOrigin[fi]
      fi++
    } else {
      hyphOrigin[hi] = trimmedOrigin[Math.max(0, fi - 1)]
    }
  }

  let prepText = ""
  for (let i = 0; i < hyphenated.length; i++) {
    prepText += hyphenated[i] === "-" ? NON_BREAKING_HYPHEN : hyphenated[i]
  }

  const prepared = prepareWithSegments(prepText, font)
  const starts = segmentCharStarts(prepared.segments)
  prepared.widths = prepared.segments.map((seg, index) => {
    const start = starts[index]
    return measureSegment(seg, hyphOrigin, start, snapshot, font)
  })
  const normalSpaceWidth = measureText(" ", font)
  const hyphenWidth = measureText("-", font)
  return {prepared, hyphOrigin, normalSpaceWidth, hyphenWidth}
}

function segmentCharStarts(segments) {
  const starts = new Int32Array(segments.length)
  let start = 0
  for (let i = 0; i < segments.length; i++) {
    starts[i] = start
    start += segments[i].length
  }
  return starts
}

function measureSegment(seg, origin, start, snapshot, fallbackFont) {
  if (seg === SOFT_HYPHEN) return 0
  let width = 0
  let runFont = null
  let runText = ""
  for (let i = 0; i < seg.length; i++) {
    const entry = snapshot[origin[start + i] ?? 0]
    const font = entry?.font ?? fallbackFont
    if (runFont !== null && font !== runFont) {
      width += measureText(runText, runFont)
      runText = ""
    }
    runFont = font
    runText += seg[i]
  }
  if (runText !== "") width += measureText(runText, runFont ?? fallbackFont)
  return width
}

function applyLayout(snapshot, prep, maxWidth) {
  const breaks = findBreaks(prep.prepared, maxWidth, prep.normalSpaceWidth, prep.hyphenWidth)
  const out = renderKPText(prep.prepared, breaks, prep.hyphOrigin, snapshot.length)
  for (let i = 0; i < snapshot.length; i++) {
    const entry = snapshot[i]
    if (entry.textNode.isConnected) entry.textNode.nodeValue = out[i]
  }
}

function renderKPText(prepared, breaks, charOrigin, snapshotLength) {
  const segments = prepared.segments
  const segCharStart = new Int32Array(segments.length + 1)
  let pos = 0
  for (let s = 0; s < segments.length; s++) {
    segCharStart[s] = pos
    pos += segments[s].length
  }
  segCharStart[segments.length] = pos

  const breakAt = new Map(breaks.map(b => [b.segIndex, b.kind]))
  const buckets = []
  for (let i = 0; i < snapshotLength; i++) buckets.push([])

  for (let i = 0; i < segments.length; i++) {
    const seg = segments[i]
    const segStart = segCharStart[i]
    const breakKind = breakAt.has(i + 1) ? breakAt.get(i + 1) : null

    if (seg === SOFT_HYPHEN) {
      if (breakKind === "soft-hyphen") {
        const o = charOrigin[segStart] ?? 0
        buckets[o].push(SOFT_HYPHEN)
      }
    } else if (isWhitespace(seg)) {
      const o = charOrigin[segStart] ?? 0
      buckets[o].push(breakKind === "space" ? " " : NBSP)
    } else {
      for (let j = 0; j < seg.length; j++) {
        const o = charOrigin[segStart + j] ?? 0
        buckets[o].push(seg[j])
      }
    }
  }

  return buckets.map(b => b.join(""))
}

function findBreaks(prepared, maxWidth, normalSpaceWidth, hyphenWidth) {
  const segments = prepared.segments
  const widths = prepared.widths
  const n = segments.length
  if (n === 0) return []

  const isShy = new Uint8Array(n)
  const isSpaceArr = new Uint8Array(n)
  for (let i = 0; i < n; i++) {
    isShy[i] = segments[i] === SOFT_HYPHEN ? 1 : 0
    isSpaceArr[i] = (!isShy[i] && isWhitespace(segments[i])) ? 1 : 0
  }

  const breaks = [{segIndex: 0, kind: "start"}]
  for (let i = 0; i < n - 1; i++) {
    if (isShy[i]) breaks.push({segIndex: i + 1, kind: "soft-hyphen"})
    else if (isSpaceArr[i]) breaks.push({segIndex: i + 1, kind: "space"})
  }
  breaks.push({segIndex: n, kind: "end"})

  const prefixWordW = new Float64Array(n + 1)
  const prefixSpaces = new Int32Array(n + 1)
  for (let i = 0; i < n; i++) {
    prefixWordW[i + 1] = prefixWordW[i] + (isShy[i] || isSpaceArr[i] ? 0 : widths[i])
    prefixSpaces[i + 1] = prefixSpaces[i] + isSpaceArr[i]
  }

  const dp = new Float64Array(breaks.length).fill(Infinity)
  const prev = new Int32Array(breaks.length).fill(-1)
  dp[0] = 0

  for (let to = 1; to < breaks.length; to++) {
    const isLast = to === breaks.length - 1
    for (let from = to - 1; from >= 0; from--) {
      if (dp[from] === Infinity) continue
      const stats = lineStats(breaks, from, to, prefixWordW, prefixSpaces, isSpaceArr, hyphenWidth, normalSpaceWidth)
      if (stats.naturalW > maxWidth * 1.6 && !isLast) break
      const total = dp[from] + badness(stats, maxWidth, normalSpaceWidth, isLast)
      if (total < dp[to]) {
        dp[to] = total
        prev[to] = from
      }
    }
  }

  const path = []
  let cur = breaks.length - 1
  while (cur > 0) {
    if (prev[cur] === -1) { path.length = 0; break }
    path.push(cur)
    cur = prev[cur]
  }
  path.reverse()
  return path.slice(0, -1).map(b => breaks[b])
}

function lineStats(breaks, fromBreak, toBreak, prefixWordW, prefixSpaces, isSpaceArr, hyphenWidth, normalSpaceWidth) {
  const from = breaks[fromBreak].segIndex
  const to = breaks[toBreak].segIndex
  const toKind = breaks[toBreak].kind
  let wordW = prefixWordW[to] - prefixWordW[from]
  let sp = prefixSpaces[to] - prefixSpaces[from]
  if (to > from && isSpaceArr[to - 1]) sp -= 1
  if (toKind === "soft-hyphen") wordW += hyphenWidth
  return {wordW, sp, naturalW: wordW + sp * normalSpaceWidth, toKind}
}

function badness(stats, maxWidth, normalSpaceWidth, isLast) {
  if (stats.naturalW > maxWidth) return HUGE_BADNESS
  if (isLast) return 0
  let p
  if (stats.sp <= 0) {
    const slack = maxWidth - stats.wordW
    p = slack * slack * 10
  } else {
    const justified = (maxWidth - stats.wordW) / stats.sp
    const ratio = (justified - normalSpaceWidth) / normalSpaceWidth
    p = ratio * ratio * ratio * 1000
    if (justified > normalSpaceWidth * MAX_SPACE_RATIO) {
      const excess = justified / normalSpaceWidth - MAX_SPACE_RATIO
      p += excess * excess * 4000
    }
  }
  if (stats.toKind === "soft-hyphen") p += 100
  return p
}

function isWhitespace(s) {
  return s.length > 0 && s.trim().length === 0
}

function fontShorthand(style) {
  return `${style.fontStyle} ${style.fontVariant} ${style.fontWeight} ${style.fontSize} ${style.fontFamily}`
}

function measureText(text, font) {
  measuringContext.font = font
  return measuringContext.measureText(text).width
}
