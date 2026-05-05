// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `bun add --cwd assets some-package` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/sheaf"
import topbar from "../vendor/topbar"
import {KnuthPlass} from "./knuth_plass"
import {DocumentBreadcrumb} from "./document_breadcrumb"
import {DataTable} from "./data_table"
import {ScrollContainer} from "./scroll_container"
import {SubmitShortcut} from "./submit_shortcut"
import {AssistantTypeWriter} from "./assistant_typewriter"
import {installBlockPreviewAnchors} from "./block_preview_anchor"
import {installCopyNormalizer} from "./copy_normalize"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const devSessionStorage = window.location.hostname.endsWith(".localhost") ?
  {
    getItem(key) {
      return key === "phx:fallback:LongPoll" ? null : window.sessionStorage?.getItem(key)
    },
    setItem(key, value) {
      if (key !== "phx:fallback:LongPoll") window.sessionStorage?.setItem(key, value)
    },
    removeItem(key) {
      window.sessionStorage?.removeItem(key)
    },
  } :
  window.sessionStorage

window.sessionStorage?.removeItem("phx:fallback:LongPoll")

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 6000,
  sessionStorage: devSessionStorage,
  params: {_csrf_token: csrfToken},
  hooks: {
    ...colocatedHooks,
    KnuthPlass,
    DocumentBreadcrumb,
    DataTable,
    ScrollContainer,
    SubmitShortcut,
    AssistantTypeWriter,
  },
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "transparent"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

installCopyNormalizer()
installBlockPreviewAnchors()

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
