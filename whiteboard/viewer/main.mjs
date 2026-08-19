// Whiteboard viewer router. Shows the explorer at "/" and the block-document
// session view at "/session/<project>/<slug>". Re-routes on browser navigation.

import { initExplorer } from "./explorer.mjs";
import { initBlockViewer } from "./blockview.mjs";

// Register the footnote extension once. The UMD globals (window.marked,
// window.markedFootnote) are set by classic scripts in index.html, which run
// before this deferred module.
if (window.marked && window.markedFootnote) {
  try { window.marked.use(window.markedFootnote()); } catch (e) { console.warn("footnote extension failed:", e); }
}

// Hot reload: the server pushes a "reload" event when a viewer asset changes.
if (typeof EventSource !== "undefined") {
  const _rs = new EventSource("/api/reload");
  _rs.addEventListener("reload", () => location.reload());
}

async function route() {
  const root = document.getElementById("root");
  root.innerHTML = "";
  const m = location.pathname.match(/^\/session\/([^/]+)\/([^/]+)(?:\/)?$/);
  if (m) {
    const project = decodeURIComponent(m[1]);
    const slug = decodeURIComponent(m[2]);
    initBlockViewer(root, project, slug);
  } else {
    initExplorer(root);
  }
}

window.addEventListener("popstate", route);
document.addEventListener("DOMContentLoaded", route);
route();