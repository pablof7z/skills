// Pi schemas and registration. Tool behavior and session state stay in tool.mjs.

export function registerWhiteboardToolDefinitions(pi, Type, {
  descriptions, withViewer, blockOps, attachKinds, tagKinds, handlers,
}) {
  const opt = (value) => Type.Optional(value);
  const lit = (value) => Type.Literal(value);
  const h = handlers;
  pi.registerTool({
    name: "wb_new", label: "Whiteboard new", description: descriptions.wb_new,
    parameters: Type.Object({ slug: Type.String({ description: "session slug; slugified to [a-z0-9-]" }) }),
    execute: withViewer(h.wb_new),
  });
  pi.registerTool({
    name: "wb_list", label: "Whiteboard list", description: descriptions.wb_list,
    parameters: Type.Object({ json: opt(Type.Boolean({ description: "return JSON array instead of plain lines" })) }),
    execute: withViewer(h.wb_list),
  });
  pi.registerTool({
    name: "wb_use", label: "Whiteboard use", description: descriptions.wb_use,
    parameters: Type.Object({ slug: Type.String({ description: '"project/slug" or just "slug" (project from cwd)' }) }),
    execute: withViewer(h.wb_use),
  });
  pi.registerTool({
    name: "wb_read", label: "Whiteboard read", description: descriptions.wb_read,
    parameters: Type.Object({
      format: opt(Type.Union([lit("md"), lit("json")])),
      path: opt(Type.String({ description: "scope to one file path (default \"default.md\")" })),
      block: opt(Type.String({ description: "filter to one block within the path (md only)" })),
    }),
    execute: withViewer(h.wb_read),
  });
  pi.registerTool({
    name: "wb_diff", label: "Whiteboard diff", description: descriptions.wb_diff,
    parameters: Type.Object({
      before: Type.Union([Type.Number({ minimum: 0 }), lit("current")]),
      after: Type.Union([Type.Number({ minimum: 0 }), lit("current")]),
      path: opt(Type.String({ description: "scope to one file path" })),
    }),
    execute: withViewer(h.wb_diff),
  });
  pi.registerTool({
    name: "wb_note", label: "Whiteboard note", description: descriptions.wb_note,
    parameters: Type.Object({ text: Type.String(), by: opt(Type.String()) }),
    execute: withViewer(h.wb_note),
  });
  pi.registerTool({
    name: "wb_change_start", label: "Whiteboard change start", description: descriptions.wb_start,
    parameters: Type.Object({ title: Type.String(), summary: opt(Type.String()), by: opt(Type.String()) }),
    execute: withViewer(h.wb_change_start),
  });
  pi.registerTool({
    name: "wb_change_block", label: "Whiteboard change block", description: descriptions.wb_block,
    parameters: Type.Object({
      op: Type.Union(blockOps.map(lit)),
      path: opt(Type.String({ description: "file path the block belongs to (default \"default.md\")" })),
      block: opt(Type.String()), name: opt(Type.String()), names: opt(Type.Array(Type.String())),
      text: opt(Type.String()), diff: opt(Type.String()),
      before: opt(Type.String()), after: opt(Type.String()), by: opt(Type.String()),
    }),
    execute: withViewer(h.wb_change_block),
  });
  pi.registerTool({
    name: "wb_attach", label: "Whiteboard attach", description: descriptions.wb_attach,
    parameters: Type.Object({
      op: Type.Union([lit("attach"), lit("reply"), lit("resolve"), lit("reopen"), lit("list")]),
      block: opt(Type.String()), on: opt(Type.String({ description: "anchor text within the block (required for attach)" })),
      kind: opt(Type.Union(attachKinds.map(lit))), content: opt(Type.String()), id: opt(Type.String()),
      by: opt(Type.String()), path: opt(Type.String()), open: opt(Type.Boolean()),
    }),
    execute: withViewer(h.wb_attach),
  });
  pi.registerTool({
    name: "wb_tag", label: "Whiteboard tag", description: descriptions.wb_tag,
    parameters: Type.Object({
      op: Type.Union([lit("set"), lit("clear"), lit("list")]),
      block: opt(Type.String()), on: opt(Type.String({ description: "anchor text within the block (required for set/clear)" })),
      kind: opt(Type.Union(tagKinds.map(lit))), content: opt(Type.String()),
      by: opt(Type.String()), path: opt(Type.String()),
    }),
    execute: withViewer(h.wb_tag),
  });
  pi.registerTool({
    name: "wb_change_finish", label: "Whiteboard change finish", description: descriptions.wb_finish,
    parameters: Type.Object({ op: Type.Union([lit("commit"), lit("abandon")]) }),
    execute: withViewer(h.wb_change_finish),
  });
  const operation = Type.Object({
    op: Type.Union(blockOps.map(lit)),
    path: opt(Type.String({ description: "file path the block belongs to (default \"default.md\")" })),
    block: opt(Type.String()), name: opt(Type.String()), names: opt(Type.Array(Type.String())),
    text: opt(Type.String()), diff: opt(Type.String()),
    before: opt(Type.String()), after: opt(Type.String()),
  });
  pi.registerTool({
    name: "wb_apply", label: "Whiteboard apply (atomic ops)", description: descriptions.wb_apply,
    parameters: Type.Object({
      title: Type.String(),
      ops: Type.Array(operation, { description: "block ops to apply as one all-or-nothing change" }),
      summary: opt(Type.String()), by: opt(Type.String()),
      dryRun: opt(Type.Boolean({ description: "compute + return per-op content deltas without writing anything" })),
    }),
    execute: withViewer(h.wb_apply),
  });
}
