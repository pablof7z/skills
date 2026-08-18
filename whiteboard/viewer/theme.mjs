// Whiteboard viewer theme switcher (auto / light / dark).
// The inline head script in index.html sets the initial data-theme before
// paint to avoid FOUC; this module owns the persistent control, re-applies the
// theme on user choice, follows OS changes when pref is "auto", and toggles the
// two highlight.js stylesheets so code highlighting matches the theme.

const KEY = "wb-theme";
const PREFS = ["auto", "light", "dark"];
const mq = matchMedia("(prefers-color-scheme: dark)");

const hlLinks = () =>
  Array.from(document.querySelectorAll('link[rel="stylesheet"][href*="highlight-github"]'));

function resolve(pref) {
  return pref === "auto" ? (mq.matches ? "dark" : "light") : pref;
}

function apply(eff) {
  document.documentElement.dataset.theme = eff;
  for (const l of hlLinks()) {
    const isDark = /highlight-github-dark/.test(l.getAttribute("href"));
    l.disabled = isDark ? eff !== "dark" : eff !== "light";
  }
}

let pref = localStorage.getItem(KEY) || "auto";
apply(resolve(pref));
mq.addEventListener("change", () => { if (pref === "auto") apply(resolve("auto")); });

const LABEL = { auto: "Auto", light: "Light", dark: "Dark" };

function renderSwitcher() {
  if (document.querySelector(".theme-switch")) return;
  const el = document.createElement("div");
  el.className = "theme-switch";
  el.setAttribute("role", "group");
  el.setAttribute("aria-label", "Theme");
  el.innerHTML = PREFS.map(
    (p) => `<button type="button" data-pref="${p}" aria-pressed="${pref === p}">${LABEL[p]}</button>`
  ).join("");
  el.addEventListener("click", (e) => {
    const btn = e.target.closest("button[data-pref]");
    if (!btn) return;
    pref = btn.dataset.pref;
    localStorage.setItem(KEY, pref);
    apply(resolve(pref));
    for (const b of el.querySelectorAll("button"))
      b.setAttribute("aria-pressed", String(b.dataset.pref === pref));
  });
  document.body.appendChild(el);
}

if (document.readyState === "loading")
  document.addEventListener("DOMContentLoaded", renderSwitcher);
else renderSwitcher();