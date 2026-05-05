const HIGHLIGHT_NAME = "sheaf-typewriter-hidden"
const DEFAULT_MIN_SPEED = 80
const DEFAULT_MAX_SPEED = 180
const FRAME_DELAY = 1000 / 60
const CHARS_PER_FRAME_LIMIT = 18

let stylesheetInstalled = false

export const AssistantTypeWriter = {
  mounted() {
    this.highlight = null
    this.blind = null
    this.timer = null
    this.limit = textLength(this.el)

    if (!supportsHighlights()) return

    installHighlightStyles()
    this.highlight = CSS.highlights.get(HIGHLIGHT_NAME) || new Highlight()
    CSS.highlights.set(HIGHLIGHT_NAME, this.highlight)
    this.blind = new Range()

    if (isStreaming(this.el)) {
      this.limit = 0
    }

    this.updateBlind()
    this.proceed()
  },

  beforeUpdate() {
    if (!supportsHighlights()) return
    this.wasStreaming = isStreaming(this.el)
    this.previousLength = textLength(this.el)
  },

  updated() {
    if (!supportsHighlights()) return

    const length = textLength(this.el)
    if (length < this.limit) this.limit = length

    this.updateBlind()

    if (this.limit < length && (isStreaming(this.el) || this.wasStreaming || length > this.previousLength)) {
      this.proceed()
    }
  },

  destroyed() {
    if (this.timer) window.clearTimeout(this.timer)
    if (this.highlight && this.blind) this.highlight.delete(this.blind)
    this.timer = null
    this.blind = null
  },

  updateBlind() {
    if (!this.highlight || !this.blind) return

    const length = textLength(this.el)

    if (this.limit >= length) {
      this.highlight.delete(this.blind)
      return
    }

    const position = textPosition(this.el, this.limit)

    if (!position) {
      this.highlight.delete(this.blind)
      return
    }

    this.blind.setStart(position.node, position.offset)
    this.blind.setEndAfter(this.el)
    this.highlight.add(this.blind)
  },

  proceed() {
    if (this.timer || !this.blind) return

    const tick = () => {
      const hidden = this.blind.toString()
      const length = textLength(this.el)

      if (this.limit >= length || hidden.trim() === "") {
        this.limit = length
        this.timer = null
        this.updateBlind()
        return
      }

      const step = revealStep(length, hidden)
      this.limit = Math.min(this.limit + step, length)
      this.updateBlind()

      const delay = Math.max(FRAME_DELAY, 1000 / adjustedSpeed(length, hidden))
      this.timer = window.setTimeout(tick, delay)
    }

    this.timer = window.setTimeout(tick, 0)
  },
}

function supportsHighlights() {
  return Boolean(window.CSS?.highlights && window.Highlight && window.Range)
}

function installHighlightStyles() {
  if (stylesheetInstalled) return
  stylesheetInstalled = true

  const css = `
    ::highlight(sheaf-typewriter-hidden) {
      color: transparent;
      text-decoration-color: transparent;
      -webkit-text-fill-color: transparent;
    }

    [phx-hook="AssistantTypeWriter"] {
      transition: opacity 120ms ease-out, filter 120ms ease-out;
    }

    [phx-hook="AssistantTypeWriter"][data-typewriter-streaming] {
      filter: saturate(1.03);
    }
  `

  if (document.adoptedStyleSheets) {
    const sheet = new CSSStyleSheet()
    sheet.replaceSync(css)
    document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet]
  } else {
    const style = document.createElement("style")
    style.textContent = css
    document.head.append(style)
  }
}

function isStreaming(element) {
  return element.dataset.typewriterStreaming === "true"
}

function textLength(element) {
  return element.textContent.length
}

function textPosition(element, limit) {
  const walk = document.createTreeWalker(element, NodeFilter.SHOW_TEXT)
  let remaining = limit

  while (walk.nextNode()) {
    const node = walk.currentNode
    const length = node.data.length

    if (remaining <= length) {
      return {node, offset: remaining}
    }

    remaining -= length
  }

  return null
}

function adjustedSpeed(length, hidden) {
  const speedRange = DEFAULT_MAX_SPEED - DEFAULT_MIN_SPEED
  const hiddenLength = hidden.length
  const visibleRatio = 1 - hiddenLength / Math.max(length, 1)
  const base = Math.round(DEFAULT_MIN_SPEED + speedRange * visibleRatio ** 2)
  const catchup = Math.min(5, Math.max(1, hiddenLength / 90))
  return (base * catchup) / delayFactor(hidden[0])
}

function revealStep(length, hidden) {
  const backlog = hidden.length
  if (backlog < 120) return 1

  const proportional = Math.ceil(backlog / 160)
  const relative = Math.ceil(length / 900)
  return Math.min(CHARS_PER_FRAME_LIMIT, Math.max(2, proportional, relative))
}

function delayFactor(grapheme) {
  const factors = {
    " ": 3,
    "\n": 18,
    ",": 7,
    ";": 8,
    ":": 9,
    ".": 10,
    "–": 8,
    "—": 12,
    "!": 15,
    "?": 15,
  }

  return factors[grapheme] || 1
}
