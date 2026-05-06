const defaultAnchorName = "--block-preview-anchor"

let currentAnchor = null
let activePreviewId = null
let activeAnchorName = null

export function installBlockPreviewAnchors() {
  document.addEventListener("pointerover", activateBlockPreviewAnchor, {passive: true})
  document.addEventListener("focusin", activateBlockPreviewAnchor)
  document.addEventListener("sheaf:block-preview-rendered", positionRenderedBlockPreview)
  window.addEventListener("phx:sheaf:block-preview-rendered", positionRenderedBlockPreview)
  window.addEventListener("resize", repositionBlockPreview, {passive: true})
  window.addEventListener("scroll", repositionBlockPreview, {passive: true, capture: true})
}

function activateBlockPreviewAnchor(event) {
  const trigger = blockPreviewTrigger(event.target)
  if (!trigger) return

  const previewId = trigger.dataset.previewId
  if (!previewId) return

  const changed = currentAnchor !== trigger || activePreviewId !== previewId
  setActiveAnchor(trigger, previewId)

  if (changed) {
    hideStalePopovers(previewId)
    trigger.dispatchEvent(new MouseEvent("click", {bubbles: true, cancelable: true, view: window}))
  } else {
    positionCurrentPopover()
  }
}

function positionRenderedBlockPreview(event) {
  const previewId = event.detail?.id
  const popover = findBlockPreviewPopover(previewId)
  if (!popover || !previewId) return

  if (previewId !== activePreviewId) {
    popover.hidden = true
    return
  }

  const trigger = findTrigger(previewId)
  if (!trigger) {
    popover.hidden = true
    clearActiveAnchor()
    return
  }

  setActiveAnchor(trigger, previewId)
  popover.hidden = false
  popover.style.setProperty("position-anchor", activeAnchorName)
  positionCurrentPopover()
}

function repositionBlockPreview() {
  positionCurrentPopover()
}

function positionCurrentPopover() {
  if (!activePreviewId || !currentAnchor?.isConnected) {
    hideStalePopovers(null)
    clearActiveAnchor()
    return
  }

  const popover = findBlockPreviewPopover(activePreviewId)
  if (!popover || popover.hidden) return

  placePopoverWithinViewport(currentAnchor, popover)
}

function setActiveAnchor(trigger, previewId) {
  if (currentAnchor && currentAnchor !== trigger) {
    currentAnchor.style.removeProperty("anchor-name")
    currentAnchor.removeAttribute("data-block-preview-active")
  }

  currentAnchor = trigger
  activePreviewId = previewId
  activeAnchorName = anchorNameForPreview(previewId)

  trigger.style.setProperty("anchor-name", `${defaultAnchorName}, ${activeAnchorName}`)
  trigger.dataset.blockPreviewActive = "true"
}

function clearActiveAnchor() {
  if (currentAnchor) {
    currentAnchor.style.removeProperty("anchor-name")
    currentAnchor.removeAttribute("data-block-preview-active")
  }

  currentAnchor = null
  activePreviewId = null
  activeAnchorName = null
}

function hideStalePopovers(previewId) {
  document.querySelectorAll(".block-preview-popover").forEach(popover => {
    if (!previewId || popover.dataset.previewId !== previewId) popover.hidden = true
  })
}

function placePopoverWithinViewport(trigger, popover) {
  const margin = 8
  const gap = 4
  const anchorRect = trigger.getBoundingClientRect()

  popover.style.removeProperty("right")
  popover.style.removeProperty("bottom")
  popover.style.left = "0px"
  popover.style.top = "0px"

  const popoverRect = popover.getBoundingClientRect()
  const width = Math.min(popoverRect.width, window.innerWidth - margin * 2)
  const height = Math.min(popoverRect.height, window.innerHeight - margin * 2)

  let left = anchorRect.left
  let top = anchorRect.bottom + gap

  if (top + height > window.innerHeight - margin) {
    top = anchorRect.top - height - gap
  }

  if (left + width > window.innerWidth - margin) {
    left = anchorRect.right - width
  }

  left = clamp(left, margin, window.innerWidth - width - margin)
  top = clamp(top, margin, window.innerHeight - height - margin)

  popover.style.left = `${Math.round(left)}px`
  popover.style.top = `${Math.round(top)}px`
}

function blockPreviewTrigger(target) {
  const element = target instanceof Element ? target : target?.parentElement
  return element?.closest(".block-preview-trigger")
}

function findTrigger(previewId) {
  return document.querySelector(`.block-preview-trigger[data-preview-id="${cssEscape(previewId)}"]`)
}

function findBlockPreviewPopover(previewId) {
  if (previewId) {
    return document.querySelector(`.block-preview-popover[data-preview-id="${cssEscape(previewId)}"]`)
  }

  return document.querySelector(".block-preview-popover")
}

function anchorNameForPreview(previewId) {
  return `--sheaf-block-preview-${previewId.replace(/[^a-zA-Z0-9_-]/g, "-")}`
}

function clamp(value, min, max) {
  if (max < min) return min
  return Math.min(Math.max(value, min), max)
}

const cssEscape = window.CSS?.escape ?? (value => `${value}`.replace(/["\\]/g, "\\$&"))
