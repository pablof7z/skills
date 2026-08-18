// Whiteboard viewer router. Decides whether to show the explorer or a session
// view based on the URL path, and re-routes on browser navigation.

import { initExplorer } from "./explorer.mjs";
import { initViewer } from "./viewer.mjs";
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
    // Decide render path by session model: block-doc (document.json) vs legacy
    // deliverable.md. Fetch metadata first so we route before building DOM.
    try {
      const s = await fetch(`/api/session/${encodeURIComponent(project)}/${encodeURIComponent(slug)}/session`).then((r) => r.json());
      if (s.model === "blocks") return initBlockViewer(root, project, slug);
    } catch {}
    initViewer(root, project, slug);
  } else {
    initExplorer(root);
  }
}

window.addEventListener("popstate", route);
document.addEventListener("DOMContentLoaded", route);
route();