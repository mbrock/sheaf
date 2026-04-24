export const ThesisBreadcrumb = {
  mounted() {
    this.article = this.el.querySelector("#document-start")
    this.document = this.article?.firstElementChild
    this.output = this.el.querySelector("#thesis-breadcrumb")
    this.copyButton = this.el.querySelector("#copy-markdown")
    this.activeSections = new Set()
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
  if (!hook.output) return

  hook.output.textContent = blockHeading(currentSection(hook))
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

function text(element) {
  return element?.textContent.trim() ?? ""
}

function flashCopied(button) {
  if (!button) return

  button.classList.add("text-stone-950", "dark:text-stone-100")
  window.setTimeout(() => button.classList.remove("text-stone-950", "dark:text-stone-100"), 700)
}
