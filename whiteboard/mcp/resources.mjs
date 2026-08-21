// Minimal Whiteboard resource surface: a session's projected document.

import { ResourceTemplate } from "@modelcontextprotocol/server";
import { loadDoc } from "../cli/doc.mjs";
import { readMdAgent } from "../cli/blocks.mjs";
import { listSessions, projectFromCwd, sessionDir } from "../cli/store.mjs";

export function registerResources(server) {
  const template = new ResourceTemplate("whiteboard://session/{project}/{slug}", {
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
    { title: "Whiteboard session", description: "A session's projected document.", mimeType: "text/markdown" },
    async (uri, { project, slug }) => {
      const doc = loadDoc(sessionDir(project, slug));
      if (!doc) throw new Error(`no session "${project}/${slug}"`);
      return { contents: [{ uri: uri.href, text: readMdAgent(doc) }] };
    },
  );
}
