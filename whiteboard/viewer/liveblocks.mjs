import { buildBlockPlan } from "./continuity.mjs";
import { renderWordDiff } from "./worddiff.mjs";

function signature(entry, detail) {
  return JSON.stringify([entry.kind, entry.old?.md || "", entry.block?.md || "", detail]);
}

function renderEntry(section, entry, renderMarkdown, detail) {
  section.className = `block${entry.kind === "same" ? "" : ` wb-${entry.kind}`}`;
  section.dataset.blockId = entry.block.name;
  section.dataset.blockPath = entry.block.path || "default.md";
  section.dataset.blockKey = entry.key;
  let className = "block-md", html;
  if (entry.kind === "changed") {
    className += " wb-diff";
    html = renderWordDiff(entry.old.md || "", entry.block.md || "", renderMarkdown, { detail });
  } else if (entry.kind === "removed") {
    className += " wb-del";
    html = renderMarkdown(entry.old.md || "");
  } else {
    if (entry.kind === "added") className += " wb-ins";
    html = renderMarkdown(entry.block.md || "");
  }
  section.innerHTML = `<div class="${className}">${html}</div>`;
}

export function createBlockReconciler({ docEl, codeblocks, renderMarkdown }) {
  async function reconcile({ beforeDoc = null, afterDoc, activePath, detail = "adaptive" }) {
    const plan = buildBlockPlan(beforeDoc, afterDoc, activePath);
    const existing = new Map([...docEl.querySelectorAll(":scope > section[data-block-key]")]
      .map((section) => [section.dataset.blockKey, section]));
    const retained = new Set(), changedKeys = new Set(), enhanced = [];
    let cursor = docEl.firstElementChild;
    for (let index = 0; index < plan.length; index++) {
      const entry = plan[index];
      const section = existing.get(entry.key) || document.createElement("section");
      const nextSignature = signature(entry, detail);
      if (section.dataset.renderSignature !== nextSignature) {
        renderEntry(section, entry, renderMarkdown, detail);
        section.dataset.renderSignature = nextSignature;
        changedKeys.add(entry.key); enhanced.push(section);
      }
      section.dataset.blockIdx = String(index);
      retained.add(section);
      if (section !== cursor) docEl.insertBefore(section, cursor);
      cursor = section.nextElementSibling;
    }
    for (const section of existing.values()) if (!retained.has(section)) section.remove();
    for (const section of enhanced) await codeblocks.enhance(section);
    return { plan, changedKeys };
  }
  return { reconcile };
}
