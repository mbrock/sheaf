// Restore plain whitespace and ASCII hyphens when the user copies text out of
// the document reader. Inside `#document-start`, the rendered DOM may contain:
//
//   * NBSPs (U+00A0) — written by KnuthPlass between words on a line, and
//     occasionally inherited from imported source HTML;
//   * non-breaking hyphens (U+2011) — written by KnuthPlass to keep hyphens
//     attached to their word;
//   * soft hyphens (U+00AD) — written by KnuthPlass at hyphenation points,
//     visible only at line breaks but always in the text.
//
// Browsers copy DOM text verbatim, so without this listener the clipboard
// gets the typographic characters, which paste oddly into editors, search
// boxes, and command lines. The dedicated "Copy as Markdown" button uses its
// own normalization in document_breadcrumb.js; this module covers ordinary
// keyboard/menu copy.
const READER_SELECTOR = "#document-start"
const SOFT_HYPHEN = "\u00AD"
const NON_BREAKING_HYPHEN = "\u2011"
const NBSP = "\u00A0"

export function installCopyNormalizer(target = document) {
  target.addEventListener("copy", handleCopy)
}

function handleCopy(event) {
  const selection = window.getSelection?.()
  if (!selection || selection.isCollapsed || selection.rangeCount === 0) return
  if (!selectionInsideReader(selection)) return

  const original = selection.toString()
  const cleaned = normalize(original)
  if (cleaned === original) return

  event.clipboardData?.setData("text/plain", cleaned)
  event.preventDefault()
}

function selectionInsideReader(selection) {
  const node = selection.anchorNode
  if (!node) return false
  const element = node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement
  return !!element?.closest(READER_SELECTOR)
}

function normalize(text) {
  return text
    .replaceAll(SOFT_HYPHEN, "")
    .replaceAll(NON_BREAKING_HYPHEN, "-")
    .replaceAll(NBSP, " ")
}
