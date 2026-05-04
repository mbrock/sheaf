const PREVIEW_SELECTOR = ".block-preview"
const TRIGGER_SELECTOR = ".block-preview-trigger"
const BACKDROP_SELECTOR = ".block-preview-backdrop"
const DISMISSED_ATTR = "data-preview-dismissed"

export function installBlockPreviewDismissal(target = document) {
  target.addEventListener("pointerdown", dismissFromBackdrop)
  target.addEventListener("pointerenter", resetFromTrigger, true)
  target.addEventListener("focusin", resetFromTrigger)
}

function dismissFromBackdrop(event) {
  const element = event.target instanceof Element ? event.target : event.target?.parentElement
  const backdrop = element?.closest(BACKDROP_SELECTOR)
  if (!backdrop) return

  const preview = backdrop.closest(PREVIEW_SELECTOR)
  if (!preview) return

  preview.setAttribute(DISMISSED_ATTR, "true")
  setPreviewHidden(preview, true)

  const active = document.activeElement
  if (active instanceof HTMLElement && preview.contains(active)) active.blur()
}

function resetFromTrigger(event) {
  const element = event.target instanceof Element ? event.target : event.target?.parentElement
  const trigger = element?.closest(TRIGGER_SELECTOR)
  const preview = trigger?.closest(PREVIEW_SELECTOR)
  if (!preview) return

  preview.removeAttribute(DISMISSED_ATTR)
  setPreviewHidden(preview, false)
}

function setPreviewHidden(preview, hidden) {
  for (const selector of [BACKDROP_SELECTOR, ".block-preview-card"]) {
    const element = preview.querySelector(selector)
    if (element instanceof HTMLElement) element.hidden = hidden
  }
}
