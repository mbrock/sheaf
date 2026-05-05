import {baseKeymap, toggleMark} from "prosemirror-commands"
import {history} from "prosemirror-history"
import {keymap} from "prosemirror-keymap"
import {DOMParser as ProseMirrorDOMParser, DOMSerializer, Schema} from "prosemirror-model"
import {schema} from "prosemirror-schema-basic"
import {EditorState} from "prosemirror-state"
import {EditorView} from "prosemirror-view"

const editorSchema = new Schema({
  nodes: schema.spec.nodes,
  marks: schema.spec.marks
    .addToEnd("underline", {
      parseDOM: [
        {tag: "u"},
        {style: "text-decoration", getAttrs: value => `${value}`.includes("underline") && null},
      ],
      toDOM() {
        return ["u", 0]
      },
    })
    .addToEnd("highlight", {
      parseDOM: [{tag: "mark"}],
      toDOM() {
        return ["mark", 0]
      },
    }),
})

export const ParagraphEditor = {
  mounted() {
    this.blockId = this.el.dataset.blockId
    this.saveButton = this.el.querySelector("[data-paragraph-editor-save]")
    this.cancelButton = this.el.querySelector("[data-paragraph-editor-cancel]")
    this.format = this.el.dataset.format || "text"
    this.initialText = this.el.dataset.text || ""
    this.initialMarkup = this.el.dataset.markup || ""
    const initialDoc = this.format === "markup" ? docFromMarkup(this.initialMarkup) : docFromText(this.initialText)
    this.initialSerializedMarkup = this.format === "markup" ? markupFromDoc(initialDoc) : ""
    this.view = new EditorView(this.el.querySelector("[data-paragraph-editor-surface]"), {
      state: EditorState.create({
        doc: initialDoc,
        plugins: [
          history(),
          keymap({
            "Mod-b": toggleMark(editorSchema.marks.strong),
            "Mod-i": toggleMark(editorSchema.marks.em),
            "Mod-u": toggleMark(editorSchema.marks.underline),
            "Mod-Enter": () => {
              this.save()
              return true
            },
            Escape: () => {
              this.cancel()
              return true
            },
          }),
          keymap(baseKeymap),
        ],
      }),
      dispatchTransaction: transaction => {
        const state = this.view.state.apply(transaction)
        this.view.updateState(state)
        this.updateSaveState()
      },
    })

    this.onSave = () => this.save()
    this.onCancel = () => this.cancel()
    this.saveButton?.addEventListener("click", this.onSave)
    this.cancelButton?.addEventListener("click", this.onCancel)
    this.updateSaveState()

    window.requestAnimationFrame(() => this.view?.focus())
  },

  destroyed() {
    this.saveButton?.removeEventListener("click", this.onSave)
    this.cancelButton?.removeEventListener("click", this.onCancel)
    this.view?.destroy()
  },

  save() {
    if (this.format === "markup") {
      const markup = markupFromDoc(this.view.state.doc)
      this.pushEvent("save_paragraph_edit", {id: this.blockId, markup})
    } else {
      const text = textFromDoc(this.view.state.doc)
      this.pushEvent("save_paragraph_edit", {id: this.blockId, text})
    }
  },

  cancel() {
    this.pushEvent("cancel_paragraph_edit", {id: this.blockId})
  },

  updateSaveState() {
    if (!this.saveButton) return
    const current =
      this.format === "markup" ? markupFromDoc(this.view.state.doc) : textFromDoc(this.view.state.doc)
    const initial = this.format === "markup" ? this.initialSerializedMarkup : this.initialText
    const unchanged = current === initial
    this.saveButton.disabled = unchanged
    this.saveButton.setAttribute("aria-disabled", unchanged ? "true" : "false")
  },
}

function docFromText(text) {
  const blocks = `${text}`.split(/\n{2,}/).map(paragraph => {
    const normalized = paragraph.replace(/\n/g, " ")
    return editorSchema.node("paragraph", null, normalized ? [editorSchema.text(normalized)] : [])
  })

  return editorSchema.node("doc", null, blocks.length ? blocks : [editorSchema.node("paragraph")])
}

function docFromMarkup(markup) {
  const wrapper = document.createElement("div")
  wrapper.innerHTML = `<p>${markup || ""}</p>`
  return ProseMirrorDOMParser.fromSchema(editorSchema).parse(wrapper)
}

function textFromDoc(doc) {
  return doc.textBetween(0, doc.content.size, "\n\n")
}

function markupFromDoc(doc) {
  const serializer = DOMSerializer.fromSchema(editorSchema)
  const container = document.createElement("div")

  doc.forEach((node, _offset, index) => {
    if (index > 0) container.appendChild(document.createElement("br"))
    if (index > 0) container.appendChild(document.createElement("br"))
    container.appendChild(serializer.serializeFragment(node.content))
  })

  return container.innerHTML
}
