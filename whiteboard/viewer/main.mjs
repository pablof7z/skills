// Whiteboard viewer router. Decides whether to show the explorer or a session
// view based on the URL path, and re-routes on browser navigation.

import { initExplorer } from "./explorer.mjs";
import { initViewer } from "./viewer.mjs";

function route() {
  const root = document.getElementById("root");
  root.innerHTML = "";
  const m = location.pathname.match(/^\/session\/([^/]+)\/([^/]+)(?:\/)?$/);
  if (m) {
    initViewer(root, decodeURIComponent(m[1]), decodeURIComponent(m[2]));
  } else {
    initExplorer(root);
  }
}

window.addEventListener("popstate", route);
document.addEventListener("DOMContentLoaded", route);
route();