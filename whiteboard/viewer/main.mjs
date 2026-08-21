// Whiteboard viewer router. Shows the explorer at "/" and the block-document
// session view at "/session/<project>/<slug>". Re-routes on browser navigation.
//
// Owns the single multiplexed SSE connection for the page (/api/stream):
// "reload" (viewer-asset change), "sessions" (explorer list changed),
// "refresh" (the viewed session's document changed). Views register for the
// events they care about via onSessions()/onRefresh()/onStatus() instead of
// opening their own EventSource — keeps each tab to one live connection
// instead of three, which used to exhaust the browser's per-origin
// connection pool after a couple of tabs and hang the page.

import { initExplorer } from "./explorer.mjs";
import { initBlockViewer } from "./blockview.mjs";

// Register the footnote extension once. The UMD globals (window.marked,
// window.markedFootnote) are set by classic scripts in index.html, which run
// before this deferred module.
if (window.marked && window.markedFootnote) {
  try { window.marked.use(window.markedFootnote()); } catch (e) { console.warn("footnote extension failed:", e); }
}

let sessionsCb = null;
let refreshCb = null;
let statusCb = null;

// Views call these to receive stream events; the returned function
// unregisters. Only one view is active at a time — route() clears all three
// before tearing down the previous view, so a view that forgets to
// unregister on destroy() can't leak into the next one.
export function onSessions(cb) { sessionsCb = cb; return () => { if (sessionsCb === cb) sessionsCb = null; }; }
export function onRefresh(cb) { refreshCb = cb; return () => { if (refreshCb === cb) refreshCb = null; }; }
export function onStatus(cb) { statusCb = cb; return () => { if (statusCb === cb) statusCb = null; }; }

function sessionKeyFor(pathname) {
  const m = pathname.match(/^\/session\/([^/]+)\/([^/]+)(?:\/)?$/);
  return m ? `${decodeURIComponent(m[1])}/${decodeURIComponent(m[2])}` : null;
}

function connectStream(key) {
  if (typeof EventSource === "undefined") return null;
  const url = key ? `/api/stream?session=${encodeURIComponent(key)}` : "/api/stream";
  const es = new EventSource(url);
  es.addEventListener("reload", () => location.reload());
  es.addEventListener("sessions", () => sessionsCb && sessionsCb());
  es.addEventListener("refresh", () => refreshCb && refreshCb());
  es.addEventListener("open", () => statusCb && statusCb("live"));
  es.addEventListener("error", () => statusCb && statusCb("bad"));
  return es;
}

let stream = null;
let currentDestroy = null;

async function route() {
  if (currentDestroy) { try { currentDestroy(); } catch {} currentDestroy = null; }
  sessionsCb = refreshCb = statusCb = null;
  const root = document.getElementById("root");
  root.innerHTML = "";
  const key = sessionKeyFor(location.pathname);
  if (stream) { try { stream.close(); } catch {} }
  stream = connectStream(key);
  if (key) {
    const [project, slug] = key.split("/");
    const v = initBlockViewer(root, project, slug);
    currentDestroy = v?.destroy || null;
  } else {
    const v = initExplorer(root);
    currentDestroy = v?.destroy || null;
  }
}

window.addEventListener("popstate", route);
document.addEventListener("DOMContentLoaded", route);
route();
