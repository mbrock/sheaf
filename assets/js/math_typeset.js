import katex from "katex"

function typesetMath(root) {
  const sources = [
    ...(root.matches?.("math") ? [root] : []),
    ...root.querySelectorAll("math"),
  ]

  sources
    .filter((source) => !source.closest(".katex"))
    .forEach((source) => {
      const latex = source.textContent?.trim()
      if (!latex) return

      const displayMode = source.getAttribute("display") === "block"
      const rendered = document.createElement(displayMode ? "div" : "span")

      rendered.className = displayMode
        ? "sheaf-math sheaf-math-display"
        : "sheaf-math sheaf-math-inline"
      rendered.dataset.mathSource = latex

      katex.render(latex, rendered, {
        displayMode,
        throwOnError: false,
        strict: "warn",
        output: "htmlAndMathml",
      })

      source.replaceWith(rendered)
    })
}

function installMathTypesetting() {
  typesetMath(document)

  const observer = new MutationObserver((mutations) => {
    mutations.forEach((mutation) => {
      mutation.addedNodes.forEach((node) => {
        if (node instanceof Element) typesetMath(node)
      })
    })
  })

  observer.observe(document.documentElement, {
    childList: true,
    subtree: true,
  })
  return observer
}

export const MathTypeset = {
  mounted() {
    typesetMath(this.el)
  },
  updated() {
    typesetMath(this.el)
  },
}

export { installMathTypesetting, typesetMath }
