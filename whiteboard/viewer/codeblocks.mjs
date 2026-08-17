// Syntax highlighting (vendored highlight.js) + Mermaid rendering (lazy CDN).
// Extracted from viewer.mjs to keep that file under the LOC limit.

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

  return {
    async enhance(root) {
      highlight(root);
      await renderMermaid(root);
    },
  };
}