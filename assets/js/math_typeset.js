import katex from "katex"

function typesetMath(root) {
  root.querySelectorAll("math").forEach((source) => {
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

export const MathTypeset = {
  mounted() {
    typesetMath(this.el)
  },
  updated() {
    typesetMath(this.el)
  },
}

export { typesetMath }
