// Whiteboard viewer theme menu (auto / light / dark) behind a top-right button.
// The inline head script in index.html sets the initial data-theme before paint
// to avoid FOUC; this module owns the button + dropdown, persists the choice in
// localStorage ("wb-theme"), follows OS changes when pref is "auto", and toggles
// the two highlight.js stylesheets so code highlighting matches the theme.

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

function syncChecked(panel) {
  for (const b of panel.querySelectorAll("button[data-pref]"))
    b.setAttribute("aria-checked", String(b.dataset.pref === pref));
}

function renderMenu() {
  if (document.querySelector(".theme-menu")) return;
  const wrap = document.createElement("div");
  wrap.className = "theme-menu";
  wrap.innerHTML = `
    <button type="button" class="theme-menu-btn" aria-haspopup="true" aria-expanded="false" aria-label="Settings" title="Settings">⚙</button>
    <div class="theme-menu-panel" hidden role="menu" aria-label="Theme">
      <div class="theme-menu-title">Theme</div>
      ${PREFS.map((p) =>
        `<button type="button" role="menuitemradio" data-pref="${p}" aria-checked="${pref === p}">${LABEL[p]}</button>`
      ).join("")}
    </div>`;
  const btn = wrap.querySelector(".theme-menu-btn");
  const panel = wrap.querySelector(".theme-menu-panel");

  const close = () => { panel.hidden = true; btn.setAttribute("aria-expanded", "false"); };
  const open = () => { panel.hidden = false; btn.setAttribute("aria-expanded", "true"); };
  const toggle = () => (panel.hidden ? open() : close());

  btn.addEventListener("click", (e) => { e.stopPropagation(); toggle(); });
  panel.addEventListener("click", (e) => {
    const b = e.target.closest("button[data-pref]");
    if (!b) return;
    pref = b.dataset.pref;
    localStorage.setItem(KEY, pref);
    apply(resolve(pref));
    syncChecked(panel);
    close();
  });
  document.addEventListener("click", (e) => { if (!wrap.contains(e.target)) close(); });
  document.addEventListener("keydown", (e) => { if (e.key === "Escape") close(); });

  document.body.appendChild(wrap);
}

if (document.readyState === "loading")
  document.addEventListener("DOMContentLoaded", renderMenu);
else renderMenu();