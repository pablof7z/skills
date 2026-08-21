// Word-level inline diff for the whiteboard block viewer.
//
// Given the previous and current markdown for a block, produce HTML that shows
// the change inline: deleted words as <del> (red strike) and inserted words as
// <ins> (green), with unchanged lines rendered as normal markdown. A single-word
// edit renders as "... <del>nice</del> <ins>better</ins> ...".
//
// Approach: line-level LCS (so multi-line constructs like lists and code fences
// stay intact), then pair each adjacent deleted/inserted line run as a
// modification region and run a word-level LCS across each paired line,
// wrapping changed words in <del>/<ins>. Lone inserted lines become a green
// .wb-ins block; lone deleted lines become a red .wb-del block — matching the
// line-level styles already in styles.css.
//
// renderMd: (mdString) -> sanitized HTML string (the viewer's marked + DOMPurify
// pipeline). <del>/<ins> are in DOMPurify's default HTML allow-list, so the raw
// tags we inject into the markdown source pass through marked and survive
// sanitization.

function lineLcsOps(A, B) {
  const n = A.length, m = B.length;
  const dp = Array.from({ length: n + 1 }, () => new Array(m + 1).fill(0));
  for (let i = n - 1; i >= 0; i--)
    for (let j = m - 1; j >= 0; j--)
      dp[i][j] = A[i] === B[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
  const ops = [];
  let i = 0, j = 0;
  while (i < n && j < m) {
    if (A[i] === B[j]) { ops.push({ t: "eq", line: A[i] }); i++; j++; }
    else if (dp[i + 1][j] >= dp[i][j + 1]) { ops.push({ t: "del", line: A[i] }); i++; }
    else { ops.push({ t: "ins", line: B[j] }); j++; }
  }
  while (i < n) { ops.push({ t: "del", line: A[i] }); i++; }
  while (j < m) { ops.push({ t: "ins", line: B[j] }); j++; }
  return ops;
}

// Split a line into tokens, keeping whitespace runs as their own tokens so the
// word diff preserves spacing. Each token is { text, ws }.
function tokenize(line) {
  const out = [];
  const re = /(\s+|\S+)/g;
  let m;
  while ((m = re.exec(line)) !== null) out.push({ text: m[0], ws: /^\s+$/.test(m[0]) });
  return out;
}

function wordLcsOps(a, b) {
  const n = a.length, m = b.length;
  const dp = Array.from({ length: n + 1 }, () => new Array(m + 1).fill(0));
  for (let i = n - 1; i >= 0; i--)
    for (let j = m - 1; j >= 0; j--)
      dp[i][j] = a[i].text === b[j].text ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
  const ops = [];
  let i = 0, j = 0;
  while (i < n && j < m) {
    if (a[i].text === b[j].text) { ops.push({ t: "eq", tok: a[i] }); i++; j++; }
    else if (dp[i + 1][j] >= dp[i][j + 1]) { ops.push({ t: "del", tok: a[i] }); i++; }
    else { ops.push({ t: "ins", tok: b[j] }); j++; }
  }
  while (i < n) { ops.push({ t: "del", tok: a[i] }); i++; }
  while (j < m) { ops.push({ t: "ins", tok: b[j] }); j++; }
  return ops;
}

// Decide whether a paired line is still recognizably the same text. Small,
// localized edits read well inline; rewritten or fragmented lines are clearer as
// one deleted line followed by one inserted line.
function isInlineEdit(ops) {
  const words = ops.filter((op) => !op.tok.ws);
  const equal = words.filter((op) => op.t === "eq").length;
  const deleted = words.filter((op) => op.t === "del").length;
  const inserted = words.filter((op) => op.t === "ins").length;
  const changed = deleted + inserted;
  const similarity = (2 * equal) / Math.max(1, (equal + deleted) + (equal + inserted));
  let runs = 0;
  let lastChange = null;
  for (const op of words) {
    if (op.t === "eq") { lastChange = null; continue; }
    if (op.t !== lastChange) { runs++; lastChange = op.t; }
  }
  const localizedReplacement = equal > 0 && changed <= 2 && runs <= 2;
  const limitedRewrite = similarity >= 0.6 &&
    changed <= Math.max(4, Math.ceil((equal * 2 + changed) * 0.35)) && runs <= 4;
  return localizedReplacement || limitedRewrite;
}

// Render one paired (deleted, inserted) line at the most useful granularity.
// Whitespace tokens between two tokens of the same inline run stay inside the
// span; whitespace at a run boundary remains plain.
function renderPair(delLine, insLine, renderMd) {
  if (!delLine.trim() && !insLine.trim()) return "";
  if (!delLine.trim()) return `<div class="wb-ins">${renderMd(insLine)}</div>`;
  if (!insLine.trim()) return `<div class="wb-del">${renderMd(delLine)}</div>`;
  const ops = wordLcsOps(tokenize(delLine), tokenize(insLine));
  if (!isInlineEdit(ops)) {
    return `<div class="wb-del">${renderMd(delLine)}</div><div class="wb-ins">${renderMd(insLine)}</div>`;
  }
  let src = "";
  let run = null; // { tag: "del"|"ins", text }
  const flush = () => { if (run) { src += `<${run.tag}>${run.text}</${run.tag}>`; run = null; } };
  // nextNonWs: the op after index i that is not whitespace, or null
  const nextNonWs = (i) => {
    for (let k = i + 1; k < ops.length; k++) if (!ops[k].tok.ws) return ops[k];
    return null;
  };
  for (let i = 0; i < ops.length; i++) {
    const op = ops[i];
    const tok = op.tok;
    if (tok.ws) {
      if (run) {
        const nxt = nextNonWs(i);
        if (nxt && (nxt.t === "del" || nxt.t === "ins") && (nxt.t === "del" ? "del" : "ins") === run.tag) run.text += tok.text;
        else { flush(); src += tok.text; }
      } else src += tok.text;
      continue;
    }
    if (op.t === "eq") { flush(); src += tok.text; }
    else {
      const tag = op.t === "del" ? "del" : "ins";
      if (run && run.tag === tag) run.text += tok.text;
      else { flush(); run = { tag, text: tok.text }; }
    }
  }
  flush();
  return `<div class="wb-mod">${renderMd(src)}</div>`;
}

// Emit a modification region (a deleted run directly followed by an inserted
// run, or vice versa): pair the lines word-by-word, then handle any leftover
// purely-inserted or purely-deleted lines.
function emitMod(dels, inss, renderMd, out) {
  const pairs = Math.min(dels.length, inss.length);
  for (let k = 0; k < pairs; k++)
    out.push(renderPair(dels[k], inss[k], renderMd));
  for (let k = pairs; k < dels.length; k++)
    if (dels[k].trim()) out.push(`<div class="wb-del">${renderMd(dels[k])}</div>`);
  for (let k = pairs; k < inss.length; k++)
    if (inss[k].trim()) out.push(`<div class="wb-ins">${renderMd(inss[k])}</div>`);
}

export function renderWordDiff(oldContent, newContent, renderMd) {
  const ops = lineLcsOps(
    String(oldContent ?? "").split("\n"),
    String(newContent ?? "").split("\n"),
  );
  const out = [];
  let i = 0;
  while (i < ops.length) {
    const op = ops[i];
    if (op.t === "eq") {
      const lines = [];
      while (i < ops.length && ops[i].t === "eq") lines.push(ops[i].line), i++;
      if (lines.some((l) => l.trim() !== "")) out.push(renderMd(lines.join("\n")));
      continue;
    }
    if (op.t === "del") {
      const dels = [];
      while (i < ops.length && ops[i].t === "del") dels.push(ops[i].line), i++;
      const inss = [];
      while (i < ops.length && ops[i].t === "ins") inss.push(ops[i].line), i++;
      if (inss.length) emitMod(dels, inss, renderMd, out);
      else for (const d of dels) out.push(`<div class="wb-del">${renderMd(d)}</div>`);
      continue;
    }
    // op.t === "ins" — collect the ins run, then any immediately-following del
    // run, and treat the pair as a modification (ins-then-del order).
    const inss = [];
    while (i < ops.length && ops[i].t === "ins") inss.push(ops[i].line), i++;
    const dels = [];
    while (i < ops.length && ops[i].t === "del") dels.push(ops[i].line), i++;
    if (dels.length) emitMod(dels, inss, renderMd, out);
    else for (const ins of inss) out.push(`<div class="wb-ins">${renderMd(ins)}</div>`);
  }
  return out.join("");
}
