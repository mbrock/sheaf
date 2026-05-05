import {normalizeReaderText} from "./copy_normalize"

// Band of the article viewport used to decide which section is "current". The
// IntersectionObserver root is the article, so percentage rootMargin scales
// with the article's size automatically — no resize handling needed.
//   - top: 9% from the top of the article (just under the toolbar)
//   - height: 5% (a thin scan-line)
const BAND_TOP_PCT = 9
const BAND_HEIGHT_PCT = 5
const BAND_BOTTOM_PCT = 100 - BAND_TOP_PCT - BAND_HEIGHT_PCT
const BAND_ROOT_MARGIN = `-${BAND_TOP_PCT}% 0% -${BAND_BOTTOM_PCT}% 0%`

export const DocumentBreadcrumb = {
  mounted() {
    this.article = this.el.querySelector("#document-start")
    this.scrollTarget = scrollTarget(this.article)
    this.document = this.article?.firstElementChild
    this.toc = this.el.querySelector("aside")
    this.output = this.el.querySelector("#document-breadcrumb")
    this.copyButton = this.el.querySelector("#copy-markdown")
    this.activeSections = new Set()
    this.observedSections = new Set()
    this.sectionOrder = new Map()
    this.tocLinks = new Map()

    this.update = () => updateCurrentHeading(this)
    this.copy = () => copyMarkdown(this)
    this.navigateAssistantBlock = event => navigateAssistantBlock(this, event)
    this.clearSelectionFromOutsideClick = event => clearSelectionFromOutsideClick(this, event)
    this.focusArticle = () => focusArticle(this)
    this.scrollFromKey = event => scrollArticleFromKey(this, event)

    this.el.addEventListener("click", this.navigateAssistantBlock)
    document.addEventListener("pointerdown", this.clearSelectionFromOutsideClick)
    this.article?.addEventListener("pointerdown", this.focusArticle)
    window.addEventListener("keydown", this.scrollFromKey)
    this.copyButton?.addEventListener("click", this.copy)
    this.handleEvent("scroll-to-block", ({id}) => scheduleScrollToBlock(this, id))
    this.handleEvent("scroll-reader-to-top", () => scheduleScrollReaderToTop(this))

    initObserver(this)
    requestAnimationFrame(() => focusArticle(this))
  },
  updated() {
    this.article = this.el.querySelector("#document-start")
    this.scrollTarget = scrollTarget(this.article)
    refreshSections(this)
    refreshTocLinks(this)
  },
  destroyed() {
    this.observer?.disconnect()
    this.el.removeEventListener("click", this.navigateAssistantBlock)
    document.removeEventListener("pointerdown", this.clearSelectionFromOutsideClick)
    this.article?.removeEventListener("pointerdown", this.focusArticle)
    window.removeEventListener("keydown", this.scrollFromKey)
    this.copyButton?.removeEventListener("click", this.copy)
  },
}

function clearSelectionFromOutsideClick(hook, event) {
  const selectedId = hook.el.dataset.selectedBlockId
  if (!selectedId) return

  const target = event.target instanceof Element ? event.target : event.target?.parentElement
  if (!target) return

  if (target.closest(`#block-${cssEscape(selectedId)}`)) return
  if (target.closest("[data-selected-block-context]")) return
  if (target.closest("[id^='block-']")) return

  hook.pushEvent("clear_block_selection", {})
}

function navigateAssistantBlock(hook, event) {
  if (event.defaultPrevented || event.button !== 0) return
  if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return

  const target = event.target instanceof Element ? event.target : event.target?.parentElement
  const link = target?.closest('.assistant-prose a[href^="/b/"]')
  if (!link || !hook.el.contains(link)) return

  const blockId = link.pathname.split("/").filter(Boolean).pop()
  if (!blockId) return

  event.preventDefault()
  hook.pushEvent("assistant_block_link", {id: blockId})
}

function scheduleScrollToBlock(hook, id) {
  requestAnimationFrame(() => {
    requestAnimationFrame(() => scrollToBlock(hook, id))
  })
}

function scheduleScrollReaderToTop(hook) {
  requestAnimationFrame(() => {
    requestAnimationFrame(() => scrollReaderToTop(hook))
  })
}

function scrollReaderToTop(hook) {
  hook.article = hook.el.querySelector("#document-start")
  hook.scrollTarget = scrollTarget(hook.article)
  hook.scrollTarget?.scrollTo({top: 0, behavior: "smooth"})
  focusArticle(hook)
}

function scrollToBlock(hook, id) {
  hook.article = hook.el.querySelector("#document-start")
  hook.scrollTarget = scrollTarget(hook.article)
  const block = hook.el.querySelector(`#block-${cssEscape(id)}`)
  if (!block) return

  for (const details of Array.from(block.querySelectorAll("details")).reverse()) {
    details.open = true
  }

  for (let details = block.closest("details"); details; details = details.parentElement?.closest("details")) {
    details.open = true
  }

  block.scrollIntoView({block: "center", behavior: "smooth"})
  focusArticle(hook)
}

function focusArticle(hook) {
  hook.article?.focus({preventScroll: true})
}

function scrollArticleFromKey(hook, event) {
  if (!hook.article || event.defaultPrevented || event.metaKey || event.ctrlKey || event.altKey) return
  if (isInteractiveTarget(event.target)) return

  const line = 56
  const target = hook.scrollTarget || scrollTarget(hook.article)
  const metrics = scrollMetrics(target)
  const page = Math.max(120, metrics.clientHeight * 0.85)
  const key = event.key
  let top = 0

  if (key === "ArrowDown" || key === "j") top = line
  else if (key === "ArrowUp" || key === "k") top = -line
  else if (key === "PageDown" || key === "d") top = page
  else if (key === "PageUp" || key === "u") top = -page
  else if (key === " " && !event.shiftKey) top = page
  else if (key === " " && event.shiftKey) top = -page
  else if (key === "Home") top = -metrics.scrollTop
  else if (key === "End") top = metrics.scrollHeight
  else return

  event.preventDefault()
  target.scrollBy({top, behavior: "auto"})
  focusArticle(hook)
}

function isInteractiveTarget(target) {
  const element = target instanceof Element ? target : target?.parentElement
  return !!element?.closest("input, textarea, select, button, a, [contenteditable='true']")
}

function cssEscape(value) {
  if (window.CSS?.escape) return window.CSS.escape(value)
  return String(value).replace(/[^a-zA-Z0-9_-]/g, "\\$&")
}

function initObserver(hook) {
  if (!hook.article) return

  const observerRoot = hook.article.dataset.scrollTarget === "window" ? null : hook.article

  hook.observer = new IntersectionObserver(
    entries => handleObserverEntries(hook, entries),
    {root: observerRoot, rootMargin: BAND_ROOT_MARGIN}
  )
  refreshSections(hook)
  refreshTocLinks(hook)
  requestAnimationFrame(hook.update)
}

function scrollTarget(element) {
  return element?.dataset.scrollTarget === "window" ? window : element
}

function scrollMetrics(target) {
  if (target === window) {
    const element = document.scrollingElement || document.documentElement
    return {
      scrollHeight: element.scrollHeight,
      scrollTop: window.scrollY,
      clientHeight: window.innerHeight,
    }
  }

  return {
    scrollHeight: target?.scrollHeight ?? 0,
    scrollTop: target?.scrollTop ?? 0,
    clientHeight: target?.clientHeight ?? window.innerHeight,
  }
}

function handleObserverEntries(hook, entries) {
  for (const entry of entries) {
    if (entry.isIntersecting) {
      hook.activeSections.add(entry.target)
    } else {
      hook.activeSections.delete(entry.target)
    }
  }

  hook.update()
}

function refreshSections(hook) {
  if (!hook.article || !hook.observer) return

  const sections = Array.from(hook.article.querySelectorAll("section[id], details[id]"))
  const next = new Set(sections)

  for (const section of hook.observedSections) {
    if (next.has(section)) continue
    hook.observer.unobserve(section)
    hook.activeSections.delete(section)
  }

  for (const section of next) {
    if (hook.observedSections.has(section)) continue
    hook.observer.observe(section)
  }

  hook.observedSections = next
  hook.sectionOrder = new Map(sections.map((section, index) => [section, index]))
}

function refreshTocLinks(hook) {
  hook.tocLinks = tocLinks(hook)
  if (hook.currentTocLink && !hook.currentTocLink.isConnected) {
    hook.currentTocLink = null
  }
  hook.update()
}

function updateCurrentHeading(hook) {
  const section = currentSection(hook)

  if (hook.output) hook.output.textContent = blockHeading(section)

  updateCurrentTocLink(hook, section)
}

function currentSection(hook) {
  return Array.from(hook.activeSections).sort((left, right) => {
    const depth = sectionDepth(right) - sectionDepth(left)
    if (depth !== 0) return depth

    return (hook.sectionOrder.get(right) ?? 0) - (hook.sectionOrder.get(left) ?? 0)
  })[0]
}

function sectionDepth(section) {
  let depth = 0
  let current = section.parentElement?.closest("section[id], details[id]")

  while (current) {
    depth += 1
    current = current.parentElement?.closest("section[id], details[id]")
  }

  return depth
}

async function copyMarkdown(hook) {
  const root = currentSection(hook) ?? hook.document
  const markdown = root ? markdownFor(root) : ""
  if (markdown === "") return

  await navigator.clipboard.writeText(markdown)
  flashCopied(hook.copyButton)
}

function markdownFor(root) {
  if (root instanceof HTMLElement && root.matches("section.document-print-document[id]")) {
    return documentMarkdown(root)
  }
  if (root instanceof HTMLElement && root.matches("section.document-print-section[id]")) {
    return sectionMarkdown(root, 2)
  }
  if (root instanceof HTMLDetailsElement) return sectionMarkdown(root, 2)

  return Array.from(root.children)
    .flatMap(child => blockMarkdown(child, 2))
    .join("\n\n")
    .trim()
}

function documentMarkdown(section) {
  return [
    `# ${text(section.querySelector(":scope > h1"))}`,
    ...Array.from(section.querySelector(":scope > div")?.children ?? []).flatMap(child =>
      blockMarkdown(child, 2)
    ),
  ].filter(Boolean).join("\n\n")
}

function sectionMarkdown(section, level) {
  return [
    `${"#".repeat(level)} ${text(sectionHeading(section))}`,
    ...Array.from(section.querySelector(":scope > div")?.children ?? []).flatMap(child =>
      blockMarkdown(child, level + 1)
    ),
  ].filter(Boolean).join("\n\n")
}

function blockMarkdown(element, level) {
  if (element instanceof HTMLElement && element.matches("section.document-print-section[id]")) {
    return [sectionMarkdown(element, level)]
  }
  if (element instanceof HTMLDetailsElement) return [sectionMarkdown(element, level)]
  if (element instanceof HTMLHeadingElement) return [`${"#".repeat(headingLevel(element))} ${text(element)}`]
  if (element instanceof HTMLParagraphElement) return [text(element.lastElementChild ?? element)]
  if (element instanceof HTMLDivElement) {
    return Array.from(element.children).flatMap(child => blockMarkdown(child, level))
  }

  return []
}

function headingLevel(heading) {
  return Number(heading.tagName.slice(1))
}

function blockHeading(block) {
  return block?.querySelector(":scope > h1, :scope > header h2, :scope > summary h2")?.textContent.trim() ?? ""
}

function sectionHeading(section) {
  return section.querySelector(":scope > header h2, :scope > summary h2")
}

function tocLinks(hook) {
  return new Map(
    Array.from(hook.el.querySelectorAll("[data-toc-link]")).map(link => [
      link.dataset.tocLink,
      link,
    ])
  )
}

function updateCurrentTocLink(hook, section) {
  const link = tocLinkForSection(hook, section)
  if (link === hook.currentTocLink) return

  clearCurrentTocLink(hook)

  hook.currentTocLink = link
  link?.setAttribute("data-current", "true")
  link?.setAttribute("aria-current", "location")
  keepTocLinkVisible(hook, link)
}

function tocLinkForSection(hook, section) {
  if (section && hook.tocLinks.has(section.id)) return hook.tocLinks.get(section.id)
  if (hook.currentTocLink) return hook.currentTocLink

  return hook.tocLinks.values().next().value
}

function clearCurrentTocLink(hook) {
  hook.currentTocLink?.removeAttribute("data-current")
  hook.currentTocLink?.removeAttribute("aria-current")
  hook.currentTocLink = null
}

function keepTocLinkVisible(hook, link) {
  if (!hook.toc || !link) return

  const toc = hook.toc
  const tocRect = toc.getBoundingClientRect()
  const linkRect = link.getBoundingClientRect()
  const topLimit = tocRect.top + Math.min(96, toc.clientHeight * 0.18)
  const bottomLimit = tocRect.bottom - Math.min(160, toc.clientHeight * 0.28)

  if (linkRect.top >= topLimit && linkRect.bottom <= bottomLimit) return

  toc.scrollTo({
    top: Math.max(0, toc.scrollTop + linkRect.top - tocRect.top - toc.clientHeight * 0.35),
  })
}

function text(element) {
  return normalizeReaderText(element?.textContent ?? "").trim()
}

function flashCopied(button) {
  if (!button) return

  button.classList.add("text-stone-950", "dark:text-stone-100")
  window.setTimeout(() => button.classList.remove("text-stone-950", "dark:text-stone-100"), 700)
}
