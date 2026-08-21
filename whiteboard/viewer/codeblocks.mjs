// Syntax highlighting (vendored highlight.js) + Mermaid rendering (lazy CDN),
// plus a fullscreen overlay for code blocks and diagrams. Extracted from
// viewer.mjs to keep that file under the LOC limit.

export function initCodeBlocks() {
  let mermaidLoading = null;

  function highlight(root) {
    if (!window.hljs) return;
    for (const code of root.querySelectorAll("pre code")) {
      if (code.classList.contains("language-mermaid")) continue;
      if (code.dataset.highlighted) continue;
      try { window.hljs.highlightElement(code); code.dataset.highlighted = "yes"; } catch {}
    }
  }

  function loadMermaid() {
    if (window.mermaid) return Promise.resolve(window.mermaid);
    if (mermaidLoading) return mermaidLoading;
    mermaidLoading = new Promise((resolve, reject) => {
      const s = document.createElement("script");
      s.src = "/vendor/mermaid.min.js";
      s.onload = () => { try { window.mermaid.initialize({ startOnLoad: false, securityLevel: "loose" }); } catch {} resolve(window.mermaid); };
      s.onerror = () => reject(new Error("mermaid load failed"));
      document.head.appendChild(s);
    });
    return mermaidLoading;
  }

  // Render mermaid blocks. The original graph definition is stashed on
  // data-mermaid-src so the fullscreen view can re-render it fresh (cloning the
  // rendered SVG breaks — duplicate ids defeat mermaid's scoped styles, and the
  // inline max-width keeps it tiny).
  async function renderMermaid(root) {
    const blocks = [...root.querySelectorAll("pre code.language-mermaid")];
    if (blocks.length === 0) return;
    try {
      const mermaid = await loadMermaid();
      const nodes = [];
      for (const code of blocks) {
        const pre = code.parentElement;
        if (!pre) continue;
        const src = code.textContent;
        const div = document.createElement("div");
        div.className = "mermaid";
        div.textContent = src;
        div.dataset.mermaidSrc = src;
        pre.replaceWith(div);
        nodes.push(div);
      }
      await mermaid.run({ nodes });
    } catch {
      // offline / load failed: leave as a code block
    }
  }

  // Build the overlay shell (title bar + close + content area). Returns
  // { ov, content, close } so callers can populate content and wire close.
  function buildOverlay(title) {
    const ov = document.createElement("div");
    ov.className = "fs-overlay";
    ov.innerHTML = `<div class="fs-bar"><span class="fs-title"></span><button class="fs-close" type="button" aria-label="Close">✕</button></div><div class="fs-content"></div>`;
    ov.querySelector(".fs-title").textContent = title;
    document.body.appendChild(ov);
    const close = () => { ov.remove(); document.removeEventListener("keydown", onKey); document.removeEventListener("fullscreenchange", onFs); };
    const onKey = (e) => { if (e.key === "Escape") close(); };
    const onFs = () => { if (!document.fullscreenElement) close(); };
    ov.querySelector(".fs-close").addEventListener("click", close);
    ov.addEventListener("click", (e) => { if (e.target === ov) close(); });
    document.addEventListener("keydown", onKey);
    document.addEventListener("fullscreenchange", onFs);
    if (ov.requestFullscreen) ov.requestFullscreen().catch(() => {});
    return { ov, content: ov.querySelector(".fs-content"), close };
  }

  function openCodeFullscreen(pre) {
    const { content } = buildOverlay("Code");
    content.appendChild(pre.cloneNode(true));
  }

  // Render the diagram from its source via mermaid.render (explicit SVG
  // output) into a fresh node; fall back to cloning the original rendered SVG
  // if render throws (e.g. re-init hiccup) so we never show an empty box.
  async function openDiagramFullscreen(src, originalNode) {
    const { content } = buildOverlay("Diagram");
    const stage = document.createElement("div");
    stage.className = "mermaid";
    content.appendChild(stage);
    try {
      if (window.mermaid && src) {
        const id = "mermaid-fs-" + Date.now();
        const res = await window.mermaid.render(id, src);
        stage.innerHTML = res.svg;
        if (res.bindFunctions) try { res.bindFunctions(stage); } catch {}
        return;
      }
    } catch (e) { /* fall through to clone */ }
    if (originalNode) stage.appendChild(originalNode.cloneNode(true));
    else stage.textContent = src || "";
  }

  function wireFullscreen(root) {
    for (const pre of root.querySelectorAll("pre")) {
      if (pre.querySelector("code.language-mermaid")) continue;
      pre.classList.add("fs-target");
      const btn = document.createElement("button");
      btn.type = "button"; btn.className = "fs-expand"; btn.setAttribute("aria-label", "Open fullscreen"); btn.textContent = "⤢";
      btn.dataset.wbAnchorIgnore = "";
      btn.addEventListener("click", (e) => { e.stopPropagation(); openCodeFullscreen(pre); });
      pre.appendChild(btn);
    }
    for (const m of root.querySelectorAll(".mermaid")) {
      m.classList.add("fs-target", "fs-clickable");
      m.addEventListener("click", () => openDiagramFullscreen(m.dataset.mermaidSrc || m.textContent, m));
    }
  }

  return {
    async enhance(root) {
      highlight(root);
      await renderMermaid(root);
      wireFullscreen(root);
    },
  };
}
