export const ThesisBreadcrumb = {
  mounted() {
    this.article = this.el.querySelector("#document-start")
    this.document = this.article?.firstElementChild
    this.toc = this.el.querySelector("aside")
    this.output = this.el.querySelector("#thesis-breadcrumb")
    this.copyButton = this.el.querySelector("#copy-markdown")
    this.activeSections = new Set()
    this.tocLinks = new Map()
    this.update = () => updateCurrentHeading(this)
    this.observe = () => observeSections(this)
    this.copy = () => copyMarkdown(this)

    window.addEventListener("resize", this.observe)
    this.el.addEventListener("toggle", this.observe, true)
    this.copyButton?.addEventListener("click", this.copy)

    this.observe()
  },
  updated() {
    this.observe()
  },
  destroyed() {
    this.observer?.disconnect()
    window.removeEventListener("resize", this.observe)
    this.el.removeEventListener("toggle", this.observe, true)
    this.copyButton?.removeEventListener("click", this.copy)
  },
}

function observeSections(hook) {
  hook.observer?.disconnect()
  hook.activeSections.clear()

  if (!hook.article) return

  hook.sections = Array.from(hook.article.querySelectorAll("section[id], details[id]"))
  hook.sectionOrder = new Map(hook.sections.map((section, index) => [section, index]))
  hook.tocLinks = tocLinks(hook)
  clearCurrentTocLink(hook)
  hook.observer = new IntersectionObserver(entries => {
    for (const entry of entries) {
      if (entry.isIntersecting) {
        hook.activeSections.add(entry.target)
      } else {
        hook.activeSections.delete(entry.target)
      }
    }

    hook.update()
  }, {
    root: hook.article,
    rootMargin: activationBandMargin(hook.article),
  })

  for (const section of hook.sections) hook.observer.observe(section)
  requestAnimationFrame(hook.update)
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

function activationBandMargin(article) {
  const top = Math.min(64, article.clientHeight * 0.1)
  const height = 24
  const bottom = Math.max(0, article.clientHeight - top - height)

  return `-${top}px 0px -${bottom}px 0px`
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
  if (root instanceof HTMLElement && root.matches("section[id]")) return documentMarkdown(root)
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
    `${"#".repeat(level)} ${text(section.querySelector(":scope > summary h2"))}`,
    ...Array.from(section.querySelector(":scope > div")?.children ?? []).flatMap(child =>
      blockMarkdown(child, level + 1)
    ),
  ].filter(Boolean).join("\n\n")
}

function blockMarkdown(element, level) {
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
  return block?.querySelector(":scope > h1, :scope > summary h2")?.textContent.trim() ?? ""
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
  return element?.dataset?.pretextSourceText ?? element?.textContent.trim() ?? ""
}

function flashCopied(button) {
  if (!button) return

  button.classList.add("text-stone-950", "dark:text-stone-100")
  window.setTimeout(() => button.classList.remove("text-stone-950", "dark:text-stone-100"), 700)
}
