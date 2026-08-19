// scan.mjs (extension) — session listing + unread helpers for the pi extension.
// The pure actionable-item helpers live in cli/scan.mjs and are re-exported here
// so the extension imports one module; the factory owns wake-dedupe state.

import fs from "node:fs";
import path from "node:path";
import { isBlockDocDir, loadDoc } from "../cli/doc.mjs";
import { actionableComments, chatActionable, isActionable, actionableItems } from "../cli/scan.mjs";

export { isActionable, actionableComments, chatActionable, actionableItems, loadDoc };
export const isBlockDoc = isBlockDocDir;
export const isSessionDir = (n) => /^\d{4}-\d{2}-.+/.test(n);

function readJson(p, fallback) {
  try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch { return fallback; }
}

export function listSessions(root) {
  const out = [];
  if (!fs.existsSync(root)) return out;
  for (const project of fs.readdirSync(root)) {
    const pd = path.join(root, project);
    if (!fs.statSync(pd).isDirectory()) continue;
    for (const name of fs.readdirSync(pd)) {
      if (!isSessionDir(name)) continue;
      const dir = path.join(pd, name);
      if (!fs.statSync(dir).isDirectory() || !isBlockDoc(dir)) continue;
      const manifest = readJson(path.join(dir, "manifest.json"), null);
      out.push({ project, slug: name, dir, owner: manifest?.owner || null });
    }
  }
  return out;
}

// Unread count for a single session (footer badge) = actionable unresolved user
// comments + unanswered user chat messages.
export function sessionUnread(s) {
  const doc = loadDoc(s.dir);
  let n = doc ? actionableComments(doc).length : 0;
  n += chatActionable(s.dir).length;
  return n;
}