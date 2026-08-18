// Compact ToC rail for narrow viewports.
// Wide: labeled rail, document keeps the 208px left gutter.
// Narrow: peek of dots; tap opens an overlay; tap a heading, outside, or
// Escape closes it. Shared by blockview.mjs and nav.mjs.

export const TOC_COMPACT_MAX = 1100;

export function isCompactWidth(w) {
  return Number(w) <= TOC_COMPACT_MAX;
}

// compact + collapsed + any tap → open, swallow (labels unknown).
// compact + open + heading tap → close, let the jump run.
// compact + open + rail chrome → stay open.
// wide → not compact, never swallow.
export function peekClick(compact, open, targetIsItem) {
  if (!compact) return { open: false, consume: false };
  if (!open) return { open: true, consume: true };
  if (targetIsItem) return { open: false, consume: false };
  return { open: true, consume: false };
}

export function initTocRail(rail) {
  if (!rail) return { refresh() {}, destroy() {} };
  rail.setAttribute("aria-label", "Contents");
  let open = false;

  const width = () => (typeof window === "undefined" ? TOC_COMPACT_MAX + 1 : window.innerWidth);

  const apply = () => {
    const compact = isCompactWidth(width());
    document.documentElement.classList.toggle("toc-compact", compact);
    rail.classList.toggle("is-open", compact && open);
    rail.setAttribute("aria-expanded", compact ? String(open) : "true");
    if (!compact) open = false;
  };

  const onRailClick = (e) => {
    const next = peekClick(isCompactWidth(width()), open, !!e.target.closest(".toc-item"));
    open = next.open;
    apply();
    if (next.consume) {
      e.preventDefault();
      e.stopPropagation();
    }
  };

  const onDocClick = (e) => {
    if (!isCompactWidth(width()) || !open) return;
    if (!rail.contains(e.target)) { open = false; apply(); }
  };

  const onKey = (e) => {
    if (e.key === "Escape" && open) { open = false; apply(); }
  };

  rail.addEventListener("click", onRailClick, true);
  document.addEventListener("click", onDocClick);
  document.addEventListener("keydown", onKey);
  window.addEventListener("resize", apply);
  apply();

  return {
    refresh: apply,
    destroy() {
      rail.removeEventListener("click", onRailClick, true);
      document.removeEventListener("click", onDocClick);
      document.removeEventListener("keydown", onKey);
      window.removeEventListener("resize", apply);
      document.documentElement.classList.remove("toc-compact");
      rail.classList.remove("is-open");
    },
  };
}
