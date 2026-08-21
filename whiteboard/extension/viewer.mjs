// viewer.mjs — shared whiteboard viewer (webui) lifecycle.
//
// Used by the pi extension's session_start + 10s heartbeat AND by the wb_*
// tool handlers, so the localhost webui is up whenever the agent touches
// whiteboard — not just at session start. One source of truth for the spawn.
//
// Spawn uses process.execPath (the running node) rather than a literal "node"
// lookup, so it doesn't depend on PATH in the detached child's env. The
// viewer's server.mjs handles EADDRINUSE by exiting cleanly, so a losing
// spawn (another session's viewer already owns the port) is a no-op, not a
// crash. Fire-and-forget: we spawn and return; the 10s heartbeat + the
// per-tool guard cover reliability, and tool calls are never blocked on the
// viewer binding.

import { spawn } from "node:child_process";
import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const VIEWER_SERVER = path.join(__dirname, "..", "viewer", "server.mjs");
const ROOT = path.join(os.homedir(), "whiteboard");
const PORT = Number(process.env.WHITEBOARD_PORT || "4318");
export const VIEWER_URL = `http://127.0.0.1:${PORT}`;

export async function isViewerUp() {
  try {
    const r = await fetch(`${VIEWER_URL}/api/sessions`);
    return r.ok;
  } catch {
    return false;
  }
}

// Spawn the viewer if it isn't already serving. Best-effort: never throws.
export async function ensureViewer() {
  if (await isViewerUp()) return;
  try {
    const child = spawn(process.execPath, [VIEWER_SERVER, ROOT, "--port", String(PORT)], {
      stdio: "ignore",
      detached: true,
    });
    child.unref?.();
    child.on?.("error", () => {}); // never let a spawn failure throw
  } catch {
    // best-effort; heartbeat / next tool call will retry
  }
}