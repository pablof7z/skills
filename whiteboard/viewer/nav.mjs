// Floating navigation overlays for the document viewer:
//  - left TOC rail: auto-generated from headings, click to jump, marks sections
//    with unviewed changes (blue dot) or agent attention markers (amber dot),
//    highlights the active section on scroll.
//  - minimap strip: document shape with change/comment/attention markers.
//  - top/bottom change bars: "N changes above/below" that scroll to the next
//    change on click.
//  - attention pill: "⚑ N to review" — DocuSign-style jump to the next agent
//    attention marker, cycling.

export function initNav({ docScroll, docEl, state }) {
  const rail = document.createElement("nav");
  rail.className = "toc-rail";
  rail.innerHTML = `<div class="toc-title">Outline</div><ol class="toc-list"></ol>`;
  document.body.appendChild(rail);

  const minimap = document.createElement("div");
  minimap.className = "minimap";
  minimap.innerHTML = `<canvas class="minimap-canvas"></canvas>`;
  document.body.appendChild(minimap);

  const barTop = document.createElement("div");
  const barBottom = document.createElement("div");
  barTop.className = "change-bar top"; barBottom.className = "change-bar bottom";
  barTop.hidden = true; barBottom.hidden = true;
  document.body.appendChild(barTop); document.body.appendChild(barBottom);

  const attBar = document.createElement("div");
  attBar.className = "attention-bar";
  attBar.hidden = true;
  document.body.appendChild(attBar);

  let headings = [];
  let targets = []; // change/comment targets for the top/bottom bars
  let attTargets = []; // { el, top } agent attention markers (non-resolved)
  let ticking = false;

  const sectionRange = (i) => {
    const start = headings[i].el.offsetTop;
    const end = i + 1 < headings.length ? headings[i + 1].el.offsetTop : docEl.scrollHeight;
    return [start, end];
  };
  const inRange = (top, a, b) => top >= a && top < b;

  function buildTOC() {
    const list = rail.querySelector(".toc-list");
    list.innerHTML = "";
    headings = [...docEl.querySelectorAll("h1, h2, h3")].map((el) => ({ el, level: el.tagName.toLowerCase(), text: el.textContent.trim() }));
    for (let i = 0; i < headings.length; i++) {
      const h = headings[i];
      const [a, b] = sectionRange(i);
      const hasChanges = targets.some((t) => inRange(t.top, a, b));
      const hasAtt = attTargets.some((t) => inRange(t.top, a, b));
      const li = document.createElement("li");
      li.className = `toc-item toc-${h.level}` + (hasChanges ? " has-changes" : "") + (hasAtt ? " has-attention" : "");
      li.innerHTML = `<span class="dot" aria-hidden="true"></span><span class="toc-text">${esc(h.text)}</span>`;
      li.addEventListener("click", () => h.el.scrollIntoView({ behavior: "smooth", block: "start" }));
      list.appendChild(li);
    }
  }

  function collectTargets() {
    const sels = state.diffMode ? ".wb-ins, .wb-del" : "mark.wb-anno";
    targets = [...docEl.querySelectorAll(sels)].map((el) => ({ el, top: el.offsetTop, kind: el.classList.contains("wb-del") ? "del" : "ins" }));
  }

  function collectAttention() {
    attTargets = [];
    for (const a of (state.annotations || [])) {
      if (a.motivation !== "highlighting") continue;
      if (state.resolved && state.resolved.has(a.id)) continue;
      const id = a.id.split(":").pop();
      const el = docEl.querySelector(`mark.wb-attention[data-anno-id="${id}"]`);
      if (el) attTargets.push({ el, top: el.offsetTop, id });
    }
  }

  function drawMinimap() {
    const canvas = minimap.querySelector(".minimap-canvas");
    const dpr = window.devicePixelRatio || 1;
    const w = 14, h = docScroll.clientHeight;
    canvas.width = w * dpr; canvas.height = h * dpr;
    canvas.style.width = `${w}px`; canvas.style.height = `${h}px`;
    const ctx = canvas.getContext("2d");
    ctx.scale(dpr, dpr);
    ctx.clearRect(0, 0, w, h);
    const docH = Math.max(1, docEl.scrollHeight);
    const vpTop = docScroll.scrollTop;
    const vpH = docScroll.clientHeight;
    const yOf = (top) => (top / docH) * h;
    ctx.fillStyle = "rgba(47,111,235,0.10)";
    ctx.fillRect(2, yOf(vpTop), w - 4, Math.max(6, (vpH / docH) * h));
    ctx.fillStyle = "#9aa0a6";
    for (const hd of headings) { const y = yOf(hd.el.offsetTop); ctx.fillRect(2, y, 6, 1); }
    for (const t of targets) {
      const y = yOf(t.top);
      ctx.fillStyle = t.kind === "del" ? "rgba(192,53,47,0.7)" : "rgba(10,138,95,0.7)";
      if (!state.diffMode) ctx.fillStyle = "rgba(47,111,235,0.7)";
      ctx.fillRect(w - 6, y, 4, 2);
    }
    for (const t of attTargets) {
      const y = yOf(t.top);
      ctx.fillStyle = "rgba(217,119,6,0.9)";
      ctx.fillRect(w - 8, y, 4, 3);
    }
  }

  function updateBars() {
    const vpTop = docScroll.scrollTop;
    const vpBottom = vpTop + docScroll.clientHeight;
    const above = targets.filter((t) => t.top + t.el.offsetHeight < vpTop).length;
    const below = targets.filter((t) => t.top > vpBottom).length;
    const label = state.diffMode ? "change" : "comment";
    barTop.hidden = above === 0; barBottom.hidden = below === 0;
    if (above > 0) barTop.innerHTML = `↑ ${above} ${label}${above === 1 ? "" : "s"} above`;
    if (below > 0) barBottom.innerHTML = `${below} ${label}${below === 1 ? "" : "s"} below ↓`;
  }

  function updateAttBar() {
    const n = attTargets.length;
    if (n === 0) { attBar.hidden = true; return; }
    attBar.hidden = false;
    attBar.innerHTML = `⚑ ${n} to review`;
  }

  function updateActive() {
    const vpTop = docScroll.scrollTop + 40;
    let active = -1;
    for (let i = 0; i < headings.length; i++) if (headings[i].el.offsetTop <= vpTop) active = i;
    rail.querySelectorAll(".toc-item").forEach((li, i) => li.classList.toggle("active", i === active));
  }

  function onScroll() {
    if (ticking) return;
    ticking = true;
    requestAnimationFrame(() => {
      updateBars(); updateActive(); drawMinimap();
      ticking = false;
    });
  }

  function jumpTo(dir) {
    const vpTop = docScroll.scrollTop;
    const vpBottom = vpTop + docScroll.clientHeight;
    let pick = null;
    if (dir === "down") pick = targets.find((t) => t.top > vpBottom);
    else { for (let i = targets.length - 1; i >= 0; i--) if (targets[i].top + targets[i].el.offsetHeight < vpTop) { pick = targets[i]; break; } }
    if (pick) pick.el.scrollIntoView({ behavior: "smooth", block: "center" });
  }

  function jumpNextAttention() {
    if (attTargets.length === 0) return;
    const vpCenter = docScroll.scrollTop + docScroll.clientHeight / 2;
    let pick = attTargets.find((t) => t.top > vpCenter);
    if (!pick) pick = attTargets[0]; // wrap around
    pick.el.scrollIntoView({ behavior: "smooth", block: "center" });
  }

  function onMinimapClick(e) {
    const rect = minimap.getBoundingClientRect();
    const ratio = (e.clientY - rect.top) / rect.height;
    docScroll.scrollTop = ratio * (docEl.scrollHeight - docScroll.clientHeight);
  }

  barTop.addEventListener("click", () => jumpTo("up"));
  barBottom.addEventListener("click", () => jumpTo("down"));
  attBar.addEventListener("click", jumpNextAttention);
  minimap.addEventListener("click", onMinimapClick);
  docScroll.addEventListener("scroll", onScroll, { passive: true });

  function refresh() {
    collectTargets();
    collectAttention();
    buildTOC();
    updateBars(); updateAttBar(); updateActive(); drawMinimap();
  }

  function destroy() {
    docScroll.removeEventListener("scroll", onScroll);
    rail.remove(); minimap.remove(); barTop.remove(); barBottom.remove(); attBar.remove();
  }

  return { refresh, destroy };
}

const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({
  "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
}[c]));