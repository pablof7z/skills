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
      s.src = "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js";
      s.onload = () => { try { window.mermaid.initialize({ startOnLoad: false, securityLevel: "loose" }); } catch {} resolve(window.mermaid); };
      s.onerror = () => reject(new Error("mermaid load failed"));
      document.head.appendChild(s);
    });
    return mermaidLoading;
  }

  async function renderMermaid(root) {
    const blocks = [...root.querySelectorAll("pre code.language-mermaid")];
    if (blocks.length === 0) return;
    try {
      const mermaid = await loadMermaid();
      const nodes = [];
      for (const code of blocks) {
        const pre = code.parentElement;
        if (!pre) continue;
        const div = document.createElement("div");
        div.className = "mermaid";
        div.textContent = code.textContent;
        pre.replaceWith(div);
        nodes.push(div);
      }
      await mermaid.run({ nodes });
    } catch {
      // offline / load failed: leave as a code block
    }
  }

  // Shared fullscreen overlay: a dark backdrop with the cloned content large,
  // a title bar + close button, and Esc/click-outside to dismiss. One overlay
  // at a time.
  function openFullscreen(title, contentNode) {
    const ov = document.createElement("div");
    ov.className = "fs-overlay";
    ov.innerHTML = `<div class="fs-bar"><span class="fs-title"></span><button class="fs-close" type="button" aria-label="Close">✕</button></div><div class="fs-content"></div>`;
    ov.querySelector(".fs-title").textContent = title;
    ov.querySelector(".fs-content").appendChild(contentNode);
    document.body.appendChild(ov);
    const close = () => { ov.remove(); document.removeEventListener("keydown", onKey); document.removeEventListener("fullscreenchange", onFs); };
    const onKey = (e) => { if (e.key === "Escape") close(); };
    const onFs = () => { if (!document.fullscreenElement) close(); };
    ov.querySelector(".fs-close").addEventListener("click", close);
    ov.addEventListener("click", (e) => { if (e.target === ov) close(); });
    document.addEventListener("keydown", onKey);
    document.addEventListener("fullscreenchange", onFs);
    // Try the real browser fullscreen too (more "bi[g]" as requested); fall
    // back gracefully if the browser rejects it.
    if (ov.requestFullscreen) ov.requestFullscreen().catch(() => {});
  }

  // Add an expand affordance + open the overlay. Code blocks get a corner
  // button (so text selection still works); diagrams (no text to select) are
  // clickable as a whole.
  function wireFullscreen(root) {
    for (const pre of root.querySelectorAll("pre")) {
      if (pre.querySelector("code.language-mermaid")) continue;
      pre.classList.add("fs-target");
      const btn = document.createElement("button");
      btn.type = "button"; btn.className = "fs-expand"; btn.setAttribute("aria-label", "Open fullscreen"); btn.textContent = "⤢";
      btn.addEventListener("click", (e) => { e.stopPropagation(); openFullscreen("Code", pre.cloneNode(true)); });
      pre.appendChild(btn);
    }
    for (const m of root.querySelectorAll(".mermaid")) {
      m.classList.add("fs-target", "fs-clickable");
      m.addEventListener("click", () => openFullscreen("Diagram", m.cloneNode(true)));
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