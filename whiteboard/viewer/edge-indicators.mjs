// edge-indicators.mjs — off-viewport edge indicator pairs: when a matching
// element is scrolled out of the doc viewport, a small pill count appears at
// the top/bottom edge; click jumps to the nearest one. Shared by blockview.mjs
// for two indicators: agent annotations the user hasn't addressed, and (in
// revision review) changed blocks scrolled out of view.

// Pure partition: given bounding rects (vs the viewport height vh), split
// into above/below groups, each sorted nearest-to-viewport first. A rect
// counts as "above" only if fully above (bottom<=2px) and "below" only if
// fully below (top>=vh-2px) — matches the prior await-edge behavior exactly.
export function partitionEdges(rects, vh) {
  const above = [], below = [];
  rects.forEach((r, index) => {
    if (r.height === 0) return;
    if (r.bottom <= 2) above.push({ index, y: r.top });
    else if (r.top >= vh - 2) below.push({ index, y: r.top });
  });
  above.sort((a, b) => b.y - a.y);
  below.sort((a, b) => a.y - b.y);
  return { above, below };
}

// Create an above/below indicator pair appended to `container`. opts:
//   className  - base class for both pills (e.g. "await-edge"); also used to
//                scope the inner flag/count/arrow element classes
//   flagIcon   - inner "flag" glyph (default "●")
//   getItems() - () => Element[] | NodeList of candidate off-screen elements
//   isActive() - () => boolean; when false both pills stay hidden
//   scrollEls  - extra elements to listen for "scroll" on, besides window
// Returns { update(), destroy() }.
export function initEdgeIndicator(container, { className, flagIcon = "●", getItems, isActive, scrollEls = [] }) {
  const make = (dir) => {
    const el = Object.assign(document.createElement("div"), { className: `${className} ${dir}`, hidden: true });
    el.innerHTML = `<span class="${className}-flag">${flagIcon}</span><span class="${className}-count">0</span><span class="${className}-arrow">${dir === "above" ? "↑" : "↓"}</span>`;
    el.addEventListener("click", () => el._target && el._target.scrollIntoView({ behavior: "smooth", block: "center" }));
    container.appendChild(el);
    return el;
  };
  const aboveEl = make("above");
  const belowEl = make("below");

  function show(el, count, target) {
    el.hidden = false;
    el.querySelector(`.${className}-count`).textContent = count;
    el._target = target;
    el.style.left = (window.innerWidth / 2) + "px";
    el.style.top = el.classList.contains("above") ? "8px" : (window.innerHeight - el.offsetHeight - 8) + "px";
  }

  function update() {
    if (!isActive()) { aboveEl.hidden = belowEl.hidden = true; return; }
    const items = [...(getItems() || [])];
    const { above, below } = partitionEdges(items.map((el) => el.getBoundingClientRect()), window.innerHeight);
    if (above.length) show(aboveEl, above.length, items[above[0].index]); else aboveEl.hidden = true;
    if (below.length) show(belowEl, below.length, items[below[0].index]); else belowEl.hidden = true;
  }

  const onTick = () => requestAnimationFrame(update);
  const listenEls = [window, ...scrollEls];
  for (const el of listenEls) el.addEventListener("scroll", onTick, { passive: true });
  window.addEventListener("resize", onTick);

  return {
    update,
    destroy() {
      for (const el of listenEls) el.removeEventListener("scroll", onTick);
      window.removeEventListener("resize", onTick);
      aboveEl.remove(); belowEl.remove();
    },
  };
}
