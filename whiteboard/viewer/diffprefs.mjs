// Personal diff-presentation preference. This changes only how revisions are
// rendered in this browser; it is never written to Whiteboard session data.

export const DIFF_DETAIL_KEY = "wb-diff-detail";
export const DIFF_DETAILS = ["adaptive", "more-detail", "before-after"];

export function normalizeDiffDetail(value) {
  return DIFF_DETAILS.includes(value) ? value : "adaptive";
}

export function loadDiffDetail(storage = globalThis.localStorage) {
  try { return normalizeDiffDetail(storage?.getItem(DIFF_DETAIL_KEY)); }
  catch { return "adaptive"; }
}

export function saveDiffDetail(value, storage = globalThis.localStorage) {
  const normalized = normalizeDiffDetail(value);
  try { storage?.setItem(DIFF_DETAIL_KEY, normalized); } catch {}
  return normalized;
}

export function mountDiffDetail(container, onChange) {
  const label = document.createElement("label");
  label.className = "diff-detail";
  label.innerHTML = `<span>Diff detail</span><select aria-label="Diff detail">
    <option value="adaptive">Adaptive (recommended)</option>
    <option value="more-detail">More detail</option>
    <option value="before-after">Before &amp; after</option>
  </select>`;
  const select = label.querySelector("select");
  select.title = "Adaptive keeps localized edits precise and shows rewrites before and after";
  select.value = loadDiffDetail();
  select.addEventListener("change", () => {
    select.value = saveDiffDetail(select.value);
    onChange?.(select.value);
  });
  container.insertBefore(label, container.querySelector(".diff-markread"));
  return { get value() { return normalizeDiffDetail(select.value); } };
}
