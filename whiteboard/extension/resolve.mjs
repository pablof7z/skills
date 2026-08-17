// resolve.mjs — resolve the current whiteboard session for a pi project and
// expose it to the agent via WB_SESSION (so `wb` commands resolve it without
// --session). Resolution order: ~/.wb/current.json[project] → most-recently-
// modified session dir under <root>/<project>/ → null (leave unset).

import fs from "node:fs";
import path from "node:path";
import os from "node:os";

const STATE_FILE = path.join(os.homedir(), ".wb", "current.json");

export function readCurrent() {
  try { return JSON.parse(fs.readFileSync(STATE_FILE, "utf8")); } catch { return null; }
}

// Most recently modified session dir under <root>/<project>/ (mtime of the dir
// itself). Returns the slug, or null if none. Used as a fallback when
// ~/.wb/current.json has no entry for this project (e.g. a session created
// outside the CLI, or a fresh checkout).
export function mostRecentSession(project, root) {
  const base = path.join(root, project);
  let entries;
  try { entries = fs.readdirSync(base, { withFileTypes: true }); } catch { return null; }
  let best = null, bestMtime = -1;
  for (const e of entries) {
    if (!e.isDirectory()) continue;
    if (!/^\d{4}-\d{2}-.+/.test(e.name)) continue;
    const dir = path.join(base, e.name);
    try {
      const st = fs.statSync(dir);
      if (st.mtimeMs > bestMtime) { bestMtime = st.mtimeMs; best = e.name; }
    } catch {}
  }
  return best;
}

// Resolve the current session slug for a project. Returns { project, slug } or
// null. Honors an existing WB_SESSION if it already matches the project (e.g.
// the agent already ran `wb use`).
export function resolveCurrentSession(project, root) {
  const cur = readCurrent();
  if (cur && cur[project]) {
    const slug = String(cur[project]).split("/").pop();
    if (slug && fs.existsSync(path.join(root, project, slug))) return { project, slug };
  }
  const slug = mostRecentSession(project, root);
  return slug ? { project, slug } : null;
}

// Set WB_SESSION for the agent process if a session was resolved.
export function applyWbSession(project, root) {
  const s = resolveCurrentSession(project, root);
  if (s) process.env.WB_SESSION = `${s.project}/${s.slug}`;
  return s;
}