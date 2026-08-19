// scan.mjs (extension) — session listing + unread helpers for the pi extension.
// The pure actionable-item helpers live in cli/scan.mjs and are re-exported here
// so the extension imports one module; the factory owns wake-dedupe state.

import fs from "node:fs";
import path from "node:path";
import { isBlockDocDir, loadDoc } from "../cli/doc.mjs";
import { actionableComments, chatActionable, isActionable, actionableItems } from "../cli/scan.mjs";

export { isActionable, actionableComments, chatActionable, actionableItems, loadDoc };
export const isBlockDoc = isBlockDocDir;
// A session dir is identified by its manifest.json, not by a slug naming
// convention. The previous date-prefix regex hid any session whose slug did
// not start with YYYY-MM- (e.g. ones created via the pi wb_new tool, which
// does not auto-prefix) from listings.
export const isSessionDir = (dir) => fs.existsSync(path.join(dir, "manifest.json"));

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
      const dir = path.join(pd, name);
      if (!fs.statSync(dir).isDirectory()) continue;
      if (!isSessionDir(dir)) continue;
      if (!isBlockDoc(dir)) continue;
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