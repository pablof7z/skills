// Floating navigation overlays for the document viewer:
//  - left TOC rail: auto-generated from headings, click to jump, marks sections
//    with unviewed changes, highlights the active section on scroll.
//  - minimap strip: document shape with change/comment markers, click to jump.
//  - top/bottom change bars: "N changes above/below" that scroll to the next
//    change on click.

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

  let headings = [];
  let targets = []; // { el, top, kind } change/comment elements to jump between
  let ticking = false;

  const sectionRange = (i) => {
    const start = headings[i].el.offsetTop;
    const end = i + 1 < headings.length ? headings[i + 1].el.offsetTop : docEl.scrollHeight;
    return [start, end];
  };
  const hasChangeInRange = (a, b) => targets.some((t) => t.top >= a && t.top < b);

  function buildTOC() {
    const list = rail.querySelector(".toc-list");
    list.innerHTML = "";
    headings = [...docEl.querySelectorAll("h1, h2, h3")].map((el) => ({ el, level: el.tagName.toLowerCase(), text: el.textContent.trim() }));
    for (let i = 0; i < headings.length; i++) {
      const h = headings[i];
      const li = document.createElement("li");
      li.className = `toc-item toc-${h.level}`;
      li.dataset.idx = String(i);
      const [a, b] = sectionRange(i);
      if (hasChangeInRange(a, b)) li.classList.add("has-changes");
      li.innerHTML = `<span class="dot" aria-hidden="true"></span><span class="toc-text">${esc(h.text)}</span>`;
      li.addEventListener("click", () => h.el.scrollIntoView({ behavior: "smooth", block: "start" }));
      list.appendChild(li);
    }
  }

  function collectTargets() {
    const sels = state.diffMode ? ".wb-ins, .wb-del" : "mark.wb-anno";
    targets = [...docEl.querySelectorAll(sels)].map((el) => ({ el, top: el.offsetTop, kind: el.classList.contains("wb-del") ? "del" : "ins" }));
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
    // viewport indicator
    ctx.fillStyle = "rgba(47,111,235,0.10)";
    ctx.fillRect(2, yOf(vpTop), w - 4, Math.max(6, (vpH / docH) * h));
    // heading ticks
    ctx.fillStyle = "var(--muted)"; ctx.fillStyle = "#9aa0a6";
    for (const hd of headings) { const y = yOf(hd.el.offsetTop); ctx.fillRect(2, y, 6, 1); }
    // change/comment markers
    for (const t of targets) {
      const y = yOf(t.top);
      ctx.fillStyle = t.kind === "del" ? "rgba(192,53,47,0.7)" : "rgba(10,138,95,0.7)";
      if (!state.diffMode) ctx.fillStyle = "rgba(47,111,235,0.7)";
      ctx.fillRect(w - 6, y, 4, 2);
    }
  }

  function updateBars() {
    const vpTop = docScroll.scrollTop;
    const vpBottom = vpTop + docScroll.clientHeight;
    const above = targets.filter((t) => t.top + t.el.offsetHeight < vpTop).length;
    const below = targets.filter((t) => t.top > vpBottom).length;
    const label = state.diffMode ? "change" : "comment";
    if (above > 0) { barTop.hidden = false; barTop.innerHTML = `↑ ${above} ${label}${above === 1 ? "" : "s"} above`; }
    else barTop.hidden = true;
    if (below > 0) { barBottom.hidden = false; barBottom.innerHTML = `${below} ${label}${below === 1 ? "" : "s"} below ↓`; }
    else barBottom.hidden = true;
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

  function onMinimapClick(e) {
    const rect = minimap.getBoundingClientRect();
    const ratio = (e.clientY - rect.top) / rect.height;
    docScroll.scrollTop = ratio * (docEl.scrollHeight - docScroll.clientHeight);
  }

  barTop.addEventListener("click", () => jumpTo("up"));
  barBottom.addEventListener("click", () => jumpTo("down"));
  minimap.addEventListener("click", onMinimapClick);
  docScroll.addEventListener("scroll", onScroll, { passive: true });

  function refresh() {
    collectTargets();
    buildTOC();
    updateBars(); updateActive(); drawMinimap();
  }

  function destroy() {
    docScroll.removeEventListener("scroll", onScroll);
    rail.remove(); minimap.remove(); barTop.remove(); barBottom.remove();
  }

  return { refresh, destroy };
}

const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({
  "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
}[c]));