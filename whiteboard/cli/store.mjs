// store.mjs — session resolution, manifest, and version hashing. The block
// document itself (changes/ log, fold, load) lives in doc.mjs; this module is
// the lower-level plumbing shared by both the CLI and the viewer/extension.

import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import crypto from "node:crypto";
import { execSync } from "node:child_process";

export const ROOT = process.env.WHITEBOARD_ROOT || path.join(os.homedir(), "whiteboard");
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

// Per-agent "current session" map: ~/.wb/owners.json, keyed by a STABLE
// per-agent identity — not the ephemeral wb PID (each wb call is a new node
// process) and not the project (which concurrent agents share). The key is:
//   - `pi:<PI_SESSION_ID>` when pi sets PI_SESSION_ID (stable across /reload,
//     changes only on /new//fork//switch; no pid recycling);
//   - else `pid:<stable-ancestor-pid>` — the agent harness process above any
//     intermediate shell (claude/codex/…), with its start time recorded to detect
//     pid recycling after the agent exits.
// This replaces the old per-project ~/.wb/current, which let concurrent agents
// clobber each other. The map is per-agent, so two agents in the same project
// each resolve to their own session.
const OWNERS_FILE = path.join(os.homedir(), ".wb", "owners.json");
const SHELLS = new Set(["bash", "-bash", "sh", "-sh", "zsh", "-zsh", "dash", "fish", "login"]);

// Stable identity of the agent harness that spawned this wb invocation.
// Returns { pid, start } where start is the ancestor's start time (to detect
// pid recycling); start is "" if ps unavailable.
function agentAncestor() {
  try {
    let cur = process.ppid, guard = 0;
    while (guard++ < 16 && cur > 1) {
      const out = execSync(`ps -o ppid=,comm=,lstart= -p ${cur}`, { stdio: ["ignore", "pipe", "ignore"] }).toString().trim();
      const m = /^(\d+)\s+(\S+)\s+(.*)$/.exec(out);
      if (!m) break;
      const ppid = Number(m[1]), comm = m[2], start = m[3];
      if (!SHELLS.has(comm)) return { pid: cur, start };
      cur = ppid;
    }
  } catch {}
  return { pid: process.ppid, start: "" };
}

// The per-agent key for the owners map (and the current ancestor start, to
// validate pid entries on lookup). pi agents use PI_SESSION_ID (no ps needed).
export function ownerKey() {
  if (process.env.PI_SESSION_ID) return { key: `pi:${process.env.PI_SESSION_ID}`, pid: null, start: null };
  const a = agentAncestor();
  return { key: `pid:${a.pid}`, pid: a.pid, start: a.start };
}

function readOwners() {
  try { return JSON.parse(fs.readFileSync(OWNERS_FILE, "utf8")); } catch { return {}; }
}

function writeOwners(o) {
  fs.mkdirSync(path.dirname(OWNERS_FILE), { recursive: true });
  fs.writeFileSync(OWNERS_FILE, JSON.stringify(o, null, 2) + "\n");
}

// Record that THIS agent is working in this session (called by wb new/wb use).
export function claimSession(project, slug) {
  const { key, start } = ownerKey();
  if (!key) return;
  const o = readOwners();
  o[key] = { project, slug, at: new Date().toISOString(), start: start || undefined };
  writeOwners(o);
}

// Resolve a --session arg ("project/slug" or just "slug" using cwd's project),
// WB_SESSION env, or THIS agent's entry in the per-agent owners map →
// { project, slug, dir }. The owners map is keyed per-agent (PI_SESSION_ID or
// stable ancestor pid), so concurrent agents never clobber each other.
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
    // per-agent owners map fallback
    const { key, pid, start } = ownerKey();
    if (key) {
      const e = readOwners()[key];
      if (e) {
        const dir = path.join(ROOT, e.project, e.slug);
        // drop stale entries: session dir gone, or ancestor pid recycled (start changed)
        const recycled = pid && start && e.start && e.start !== start;
        if (!recycled && fs.existsSync(dir)) { p = e.project; s = e.slug; }
        else { const o = readOwners(); delete o[key]; writeOwners(o); }
      }
    }
  }
  if (!s) throw new Error(`no session: pass --session <project>/<slug> or set WB_SESSION (project=${p})`);
  return { project: p, slug: s, dir: path.join(ROOT, p, s) };
}

export function sessionDir(project, slug) { return path.join(ROOT, project, slug); }

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