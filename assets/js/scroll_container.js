export const ScrollContainer = {
  mounted() {
    this.scrollTarget = scrollTarget(this.el)
    this.stickToBottom = shouldStickToBottom(this.scrollTarget)
    this.bottomButton = findBottomButton(this.el)
    this.onScroll = () => {
      this.stickToBottom = shouldStickToBottom(this.scrollTarget)
      updateBottomButton(this.bottomButton, this.stickToBottom)
    }
    this.onBottomButtonClick = () => {
      scheduleScrollToBottom(this.scrollTarget, "smooth")
    }

    this.scrollTarget.addEventListener("scroll", this.onScroll, {passive: true})
    this.bottomButton?.addEventListener("click", this.onBottomButtonClick)

    this.handleEvent("scroll-container-to-bottom", ({id, behavior} = {}) => {
      if (id && id !== this.el.id) return
      scheduleScrollToBottom(this.scrollTarget, behavior || "smooth")
    })

    if (this.el.dataset.scrollInitial === "bottom") {
      scheduleScrollToBottom(this.scrollTarget, "auto")
    }

    updateBottomButton(this.bottomButton, this.stickToBottom)
  },

  beforeUpdate() {
    this.stickToBottom = shouldStickToBottom(this.scrollTarget)
  },

  updated() {
    this.scrollTarget = scrollTarget(this.el)
    const previousButton = this.bottomButton
    this.bottomButton = findBottomButton(this.el)

    if (this.bottomButton !== previousButton) {
      previousButton?.removeEventListener("click", this.onBottomButtonClick)
      this.bottomButton?.addEventListener("click", this.onBottomButtonClick)
    }

    if (this.el.dataset.scrollStickBottom === "true" && this.stickToBottom) {
      scheduleScrollToBottom(this.scrollTarget, "auto")
    }

    updateBottomButton(this.bottomButton, this.stickToBottom)
  },

  destroyed() {
    this.scrollTarget.removeEventListener("scroll", this.onScroll)
    this.bottomButton?.removeEventListener("click", this.onBottomButtonClick)
  },
}

function scrollTarget(element) {
  return element.dataset.scrollTarget === "window" ? window : element
}

function scrollMetrics(target) {
  if (target === window) {
    const element = document.scrollingElement || document.documentElement
    return {
      scrollHeight: element.scrollHeight,
      scrollTop: window.scrollY,
      clientHeight: window.innerHeight,
    }
  }

  return {
    scrollHeight: target.scrollHeight,
    scrollTop: target.scrollTop,
    clientHeight: target.clientHeight,
  }
}

function shouldStickToBottom(target) {
  const element = target === window ? document.documentElement : target
  const threshold = Number.parseInt(element.dataset.scrollBottomThreshold || "96", 10)
  const {scrollHeight, scrollTop, clientHeight} = scrollMetrics(target)
  return scrollHeight - scrollTop - clientHeight <= threshold
}

function scheduleScrollToBottom(target, behavior) {
  requestAnimationFrame(() => {
    requestAnimationFrame(() => {
      const {scrollHeight} = scrollMetrics(target)
      target.scrollTo({top: scrollHeight, behavior})
    })
  })
}

function findBottomButton(element) {
  const id = element.id
  if (!id) return null
  return document.querySelector(`[data-scroll-bottom-button="${CSS.escape(id)}"]`)
}

function updateBottomButton(button, isAtBottom) {
  if (!button) return
  button.hidden = isAtBottom
  button.setAttribute("aria-hidden", isAtBottom ? "true" : "false")
}
