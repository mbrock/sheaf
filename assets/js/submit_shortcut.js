export const SubmitShortcut = {
  mounted() {
    this.onKeyDown = event => {
      if (event.defaultPrevented || event.isComposing) return
      if (event.key !== "Enter" || (!event.metaKey && !event.ctrlKey)) return

      const form = this.el.closest("form")
      if (!form) return

      event.preventDefault()
      form.requestSubmit()
    }

    this.el.addEventListener("keydown", this.onKeyDown)
  },

  destroyed() {
    this.el.removeEventListener("keydown", this.onKeyDown)
  },
}
