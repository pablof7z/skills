// resources.mjs — minimal resource surface for the whiteboard MCP server
// (skeleton). One template (whiteboard://session/{project}/{slug}) that
// projects a session's doc the same way wb_read does. Kept deliberately thin
// — richer resource shapes (per-file, per-block) are a later addition.

import { ResourceTemplate } from "@modelcontextprotocol/server";
import { loadDoc } from "../cli/doc.mjs";
import { readMdAgent } from "../cli/blocks.mjs";
import { listSessions, projectFromCwd, sessionDir } from "../cli/store.mjs";

export function registerResources(server, _ctx) {
  const template = new ResourceTemplate("whiteboard://session/{project}/{slug}", {
    // resources/list: the current project's sessions (project = server's cwd,
    // same resolution `wb list` uses with no --session).
    list: () => {
      const project = projectFromCwd();
      return {
        resources: listSessions(project).map((slug) => ({
          uri: `whiteboard://session/${project}/${slug}`,
          name: `${project}/${slug}`,
        })),
      };
    },
  });

  server.registerResource(
    "whiteboard-session",
    template,
    { title: "Whiteboard session", description: "A whiteboard session's projected document (agent-facing markdown).", mimeType: "text/markdown" },
    async (uri, { project, slug }) => {
      const doc = loadDoc(sessionDir(project, slug));
      if (!doc) throw new Error(`no session "${project}/${slug}"`);
      return { contents: [{ uri: uri.href, text: readMdAgent(doc) }] };
    },
  );
}
