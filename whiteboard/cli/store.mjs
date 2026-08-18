// store.mjs — session resolution, manifest, and version hashing. The block
// document itself (changes/ log, fold, load) lives in doc.mjs; this module is
// the lower-level plumbing shared by both the CLI and the viewer/extension.

import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import crypto from "node:crypto";
import { execSync } from "node:child_process";

export const ROOT = process.env.WHITEBOARD_ROOT || path.join(os.homedir(), "whiteboard");
const STATE_FILE = path.join(os.homedir(), ".wb", "current.json");
const NAME_RE = /^[a-z0-9][a-z0-9-]*$/;

export function slugify(s) {
  return String(s || "").toLowerCase().trim()
    .replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "") || "block";
}

export function validName(name) {
  if (typeof name !== "string" || !NAME_RE.test(name)) {
    throw new Error(`bad block name "${name}": use lowercase letters, digits, hyphens (e.g. tradeoffs)`);
  }
}

export function projectFromCwd(cwd = process.cwd()) {
  try {
    const common = execSync("git rev-parse --path-format=absolute --git-common-dir", { cwd, stdio: ["ignore", "pipe", "ignore"] }).toString().trim();
    return path.basename(path.dirname(common));
  } catch {
    return path.basename(cwd);
  }
}

// Resolve a --session arg ("project/slug" or just "slug" using cwd's project),
// WB_SESSION env, or ~/.wb/current.json keyed by project → { project, slug, dir }.
export function resolveSession({ session, cwd = process.cwd() } = {}) {
  const project = projectFromCwd(cwd);
  let p = project, s = null;
  if (session) {
    if (session.includes("/")) { const [a, b] = session.split("/"); p = a; s = b; }
    else { s = session; }
  } else if (process.env.WB_SESSION) {
    const v = process.env.WB_SESSION;
    if (v.includes("/")) { const [a, b] = v.split("/"); p = a; s = b; } else { s = v; }
  } else {
    const cur = readCurrent();
    if (cur && cur[p]) s = cur[p].split("/").pop();
  }
  if (!s) throw new Error(`no session: pass --session <project>/<slug>, set WB_SESSION, or run \`wb use <slug>\` (project=${p})`);
  return { project: p, slug: s, dir: path.join(ROOT, p, s) };
}

export function sessionDir(project, slug) { return path.join(ROOT, project, slug); }

function readCurrent() {
  try { return JSON.parse(fs.readFileSync(STATE_FILE, "utf8")); } catch { return null; }
}

export function setCurrent(project, slug) {
  const cur = readCurrent() || {};
  cur[project] = `${project}/${slug}`;
  fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
  fs.writeFileSync(STATE_FILE, JSON.stringify(cur, null, 2) + "\n");
}

export function listSessions(project) {
  const base = path.join(ROOT, project);
  let entries = [];
  try { entries = fs.readdirSync(base, { withFileTypes: true }); } catch { return []; }
  return entries.filter((e) => e.isDirectory())
    .map((e) => e.name)
    .filter((name) => fs.existsSync(path.join(base, name, "manifest.json")) || fs.existsSync(path.join(base, name, "changes")));
}

// Stable canonical JSON for hashing: object keys sorted, no whitespace.
function canonical(value) {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return "[" + value.map(canonical).join(",") + "]";
  const keys = Object.keys(value).sort();
  return "{" + keys.map((k) => JSON.stringify(k) + ":" + canonical(value[k])).join(",") + "}";
}

export function versionHash(blocks) {
  return crypto.createHash("sha256").update(canonical(blocks)).digest("hex").slice(0, 12);
}

// manifest.json helpers. The optional `owner` field is the pi session id that
// should be notified for this whiteboard session; the extension only wakes that
// agent (see extension/index.ts). Stamped on `wb new`/`wb use` from WB_OWNER.
export function readManifest(dir) {
  try { return JSON.parse(fs.readFileSync(path.join(dir, "manifest.json"), "utf8")); } catch { return null; }
}

function writeManifest(dir, m) {
  fs.mkdirSync(dir, { recursive: true });
  const tmp = path.join(dir, ".manifest.json.tmp");
  fs.writeFileSync(tmp, JSON.stringify(m, null, 2) + "\n");
  fs.renameSync(tmp, path.join(dir, "manifest.json"));
}

// Claim this session for the given pi session id (no-op if already owned by it).
export function stampOwner(dir, owner) {
  if (!owner) return false;
  const m = readManifest(dir) || { name: path.basename(dir), status: "exploring", project: "", createdAt: new Date().toISOString() };
  if (m.owner === owner) return false;
  m.owner = owner;
  writeManifest(dir, m);
  return true;
}

// Agent self-identification + action provenance, gathered by wb itself (no agent
// cooperation needed). Mirrors the home-directory skill's agent-name resolver:
// AGENT_IDENTITY → AGENT_NAME → AGENT_SLUG → AGENT_IDENTIFIER → NAME → WB_BY,
// normalized to [a-z0-9._-], falling back to "agent".
// Known harness signatures → stable name, checked after AI_AGENT. Grow as needed.
const HARNESS = [["PI_CODING_AGENT", "pi"], ["CLAUDECODE", "claude"], ["CODEX_HOME", "codex"]];

export function agentName() {
  const explicit = process.env.AGENT_IDENTITY || process.env.AGENT_NAME || process.env.AGENT_SLUG
    || process.env.AGENT_IDENTIFIER || process.env.NAME || process.env.WB_BY;
  let raw = explicit || process.env.AI_AGENT || "";
  if (!raw) for (const [k, name] of HARNESS) if (process.env[k]) { raw = name; break; }
  if (!raw) return "agent";
  const n = String(raw).toLowerCase().replace(/[^a-z0-9._-]/g, "-").replace(/-+/g, "-").replace(/^-|-$/g, "");
  return n || "agent";
}

// Provenance of the process writing a change — who/where it ran — so the viewer
// can attribute actions and offer "open this terminal tab". itermSessionId is
// iTerm2's per-pane GUID (the jump target); piSessionId is the pi harness session.
export function provenance() {
  return {
    pid: process.pid,
    ppid: process.ppid,
    piSessionId: process.env.PI_SESSION_ID || null,
    itermSessionId: process.env.ITERM_SESSION_ID || null,
    termSessionId: process.env.TERM_SESSION_ID || null,
    cwd: process.cwd(),
    host: os.hostname(),
  };
}