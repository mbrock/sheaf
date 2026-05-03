export const ScrollContainer = {
  mounted() {
    this.stickToBottom = shouldStickToBottom(this.el)
    this.onScroll = () => {
      this.stickToBottom = shouldStickToBottom(this.el)
    }

    this.el.addEventListener("scroll", this.onScroll, {passive: true})

    this.handleEvent("scroll-container-to-bottom", ({id, behavior} = {}) => {
      if (id && id !== this.el.id) return
      scheduleScrollToBottom(this.el, behavior || "smooth")
    })

    if (this.el.dataset.scrollInitial === "bottom") {
      scheduleScrollToBottom(this.el, "auto")
    }
  },

  beforeUpdate() {
    this.stickToBottom = shouldStickToBottom(this.el)
  },

  updated() {
    if (this.el.dataset.scrollStickBottom === "true" && this.stickToBottom) {
      scheduleScrollToBottom(this.el, "auto")
    }
  },

  destroyed() {
    this.el.removeEventListener("scroll", this.onScroll)
  },
}

function shouldStickToBottom(element) {
  const threshold = Number.parseInt(element.dataset.scrollBottomThreshold || "96", 10)
  return element.scrollHeight - element.scrollTop - element.clientHeight <= threshold
}

function scheduleScrollToBottom(element, behavior) {
  requestAnimationFrame(() => {
    requestAnimationFrame(() => {
      element.scrollTo({top: element.scrollHeight, behavior})
    })
  })
}
