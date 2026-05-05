let currentAnchor = null
let activePreviewId = null

export function installBlockPreviewAnchors() {
  document.addEventListener("pointerover", activateBlockPreviewAnchor, {passive: true})
  document.addEventListener("focusin", activateBlockPreviewAnchor)
  document.addEventListener("pointerout", deactivateBlockPreviewAnchor, {passive: true})
  document.addEventListener("sheaf:block-preview-rendered", positionRenderedBlockPreview)
}

function activateBlockPreviewAnchor(event) {
  const target = event.target instanceof Element ? event.target : event.target?.parentElement
  const trigger = target?.closest(".block-preview-trigger")
  if (!trigger) return
  const previewId = trigger.dataset.previewId
  if (!previewId) return

  if (currentAnchor && currentAnchor !== trigger) {
    currentAnchor.style.removeProperty("anchor-name")
  }

  const changed = currentAnchor !== trigger
  trigger.style.setProperty("anchor-name", "--block-preview-anchor")
  currentAnchor = trigger
  activePreviewId = previewId

  if (changed) {
    trigger.dispatchEvent(new MouseEvent("click", {bubbles: true, cancelable: true, view: window}))
  }
}

function deactivateBlockPreviewAnchor(event) {
  const target = event.target instanceof Element ? event.target : event.target?.parentElement
  const trigger = target?.closest(".block-preview-trigger")
  if (!trigger || trigger !== currentAnchor) return

  const related = event.relatedTarget instanceof Element ? event.relatedTarget : null
  if (related?.closest(".block-preview-trigger") === trigger) return

  activePreviewId = null
}

function positionRenderedBlockPreview(event) {
  const previewId = event.detail?.id
  const popover = document.querySelector(".block-preview-popover")
  if (!popover || !previewId || previewId !== activePreviewId) return

  const trigger = document.querySelector(`.block-preview-trigger[data-preview-id="${cssEscape(previewId)}"]`)
  if (!trigger) return

  if (currentAnchor && currentAnchor !== trigger) {
    currentAnchor.style.removeProperty("anchor-name")
  }

  trigger.style.setProperty("anchor-name", "--block-preview-anchor")
  currentAnchor = trigger
}

const cssEscape = window.CSS?.escape ?? (value => `${value}`.replace(/["\\]/g, "\\$&"))
