let currentAnchor = null

export function installBlockPreviewAnchors() {
  document.addEventListener("pointerover", activateBlockPreviewAnchor, {passive: true})
  document.addEventListener("focusin", activateBlockPreviewAnchor)
}

function activateBlockPreviewAnchor(event) {
  const target = event.target instanceof Element ? event.target : event.target?.parentElement
  const trigger = target?.closest(".block-preview-trigger")
  if (!trigger) return

  if (currentAnchor && currentAnchor !== trigger) {
    currentAnchor.style.removeProperty("anchor-name")
  }

  const changed = currentAnchor !== trigger
  trigger.style.setProperty("anchor-name", "--block-preview-anchor")
  currentAnchor = trigger

  if (changed) {
    trigger.dispatchEvent(new MouseEvent("click", {bubbles: true, cancelable: true, view: window}))
  }
}
