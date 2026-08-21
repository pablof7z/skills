// Word-level inline diff for the whiteboard block viewer.
//
// Given the previous and current markdown for a block, produce HTML that shows
// the change inline: deleted words as <del> (red strike) and inserted words as
// <ins> (green), with unchanged lines rendered as normal markdown. A single-word
// edit renders as "... <del>nice</del> <ins>better</ins> ...".
//
// Approach: ask Marked for block-level units, align those units, then refine
// safe prose and flat-list changes with a word-level LCS. Inserted/deleted
// Markdown regions are rendered as complete units so headings, lists, blank
// lines and code fences keep their structure.
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
      dp[i][j] = A[i].key === B[j].key ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
  const ops = [];
  let i = 0, j = 0;
  while (i < n && j < m) {
    if (A[i].key === B[j].key) { ops.push({ t: "eq", line: B[j].raw }); i++; j++; }
    else if (dp[i + 1][j] >= dp[i][j + 1]) { ops.push({ t: "del", line: A[i].raw }); i++; }
    else { ops.push({ t: "ins", line: B[j].raw }); j++; }
  }
  while (i < n) { ops.push({ t: "del", line: A[i].raw }); i++; }
  while (j < m) { ops.push({ t: "ins", line: B[j].raw }); j++; }
  return ops;
}

// Use the viewer's Markdown parser to choose presentation units. Its tokens
// keep nested lists, blockquotes, indented code, and fences intact. The simple
// line fallback is only for non-browser callers that do not supply Marked.
function markdownUnits(text, lexer) {
  if (typeof lexer !== "function") {
    return (String(text).match(/[^\n]*(?:\n|$)/g) || [])
      .filter((raw) => raw !== "")
      .map((raw) => ({ raw, key: raw.trimEnd() }));
  }
  const units = [], tokens = lexer(String(text));
  let leading = "";
  for (const token of tokens) {
    if (token.type === "space") {
      if (units.length) units[units.length - 1].raw += token.raw;
      else leading += token.raw;
      continue;
    }
    units.push({ raw: leading + token.raw, key: `${token.type}\0${token.raw.trimEnd()}` });
    leading = "";
  }
  if (leading && units.length) units[units.length - 1].raw += leading;
  return units;
}

const WORD_SEGMENTER = typeof Intl !== "undefined" && typeof Intl.Segmenter === "function"
  ? new Intl.Segmenter(undefined, { granularity: "word" })
  : null;

// Split plain prose into locale-aware words, punctuation and grapheme-like
// units, keeping whitespace runs so rendering preserves the source spacing.
// Intl.Segmenter makes CJK and emoji edits useful; the Unicode-regex fallback
// still keeps punctuation independent from neighboring words.
function tokenize(line) {
  if (WORD_SEGMENTER) {
    return [...WORD_SEGMENTER.segment(line)].map(({ segment }) => ({
      text: segment, ws: /^\s+$/u.test(segment),
    }));
  }
  const out = [];
  const re = /(\s+|[\p{L}\p{N}\p{M}_]+|[^\s])/gu;
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
function isInlineEdit(ops, detail) {
  if (detail === "before-after") return false;
  const words = ops.filter((op) => !op.tok.ws);
  const chars = (type) => words
    .filter((op) => op.t === type)
    .reduce((sum, op) => sum + [...op.tok.text].length, 0);
  const equal = chars("eq"), deleted = chars("del"), inserted = chars("ins");
  if (detail === "more-detail") return equal > 0;
  const changed = deleted + inserted;
  const similarity = (2 * equal) / Math.max(1, (2 * equal) + changed);
  let islands = 0, changing = false;
  for (const op of words) {
    if (op.t === "eq") { changing = false; continue; }
    if (!changing) { islands++; changing = true; }
  }
  const localizedReplacement = islands === 1 && equal >= 4 &&
    (changed <= 24 || similarity >= 0.45 || equal >= 18);
  const limitedRewrite = similarity >= 0.6 && islands <= 4;
  return localizedReplacement || limitedRewrite;
}

// An unchanged structural prefix is a safe container for an inline prose diff.
// Delimiters inside the body still require before/after rendering until changes
// are applied to parsed Markdown tokens or rendered text nodes.
function splitStructuralPrefix(line) {
  const m = String(line).match(/^(\s{0,3}(?:#{1,6}\s+|> ?|(?:[-+*]|\d+[.)])\s+(?:\[[ xX]\]\s+)?))(.*)$/u);
  return m ? { prefix: m[1], body: m[2] } : { prefix: "", body: String(line) };
}

function hasUnsafeMarkdown(text) {
  const block = /^(?: {4}|\t|\s{0,3}(?:```|~~~|\|))/m;
  const inline = /(?:[\\*~`]|!?\[[^\]]*\](?:\([^)]*\)|\[[^\]]*\])?|<[^>]+>|(?:^|[^\p{L}\p{N}])_{1,3}(?=\S)|(?<=\S)_{1,3}(?![\p{L}\p{N}]))/u;
  const nestedStructure = String(text).split("\n").some((line) => !!splitStructuralPrefix(line).prefix);
  return block.test(text) || inline.test(text) || nestedStructure;
}

function hasMarkdownSyntax(text) {
  return String(text).split("\n").some((line) => {
    const part = splitStructuralPrefix(line);
    return !!part.prefix || hasUnsafeMarkdown(part.body);
  });
}

// Merge one safe prose unit into Markdown source containing inline diff tags.
// Whitespace between tokens of the same run stays inside that run.
function mergeInlineSource(delLine, insLine, detail) {
  const oldPart = splitStructuralPrefix(delLine);
  const newPart = splitStructuralPrefix(insLine);
  const safeContainer = oldPart.prefix === newPart.prefix &&
    !hasUnsafeMarkdown(oldPart.body) && !hasUnsafeMarkdown(newPart.body);
  const ops = wordLcsOps(tokenize(oldPart.body), tokenize(newPart.body));
  if (!safeContainer || !isInlineEdit(ops, detail)) return null;
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
  return oldPart.prefix + src;
}

// A flat list remains one Markdown list while individual item bodies receive
// inline detail. Complex/nested items deliberately fall back as one unit.
function mergeFlatListSource(oldText, newText, detail) {
  const oldLines = oldText.trimEnd().split("\n"), newLines = newText.trimEnd().split("\n");
  const item = /^\s{0,3}(?:[-+*]|\d+[.)])\s+/;
  if (oldLines.length < 2 || oldLines.length !== newLines.length ||
      !oldLines.every((line) => item.test(line)) || !newLines.every((line) => item.test(line))) return null;
  const merged = [];
  for (let i = 0; i < oldLines.length; i++) {
    if (oldLines[i] === newLines[i]) merged.push(newLines[i]);
    else {
      const source = mergeInlineSource(oldLines[i], newLines[i], detail);
      if (source === null) return null;
      merged.push(source);
    }
  }
  return merged.join("\n");
}

// Render one paired deleted/inserted Markdown unit at useful granularity.
function renderPair(delLine, insLine, renderMd, detail) {
  if (!delLine.trim() && !insLine.trim()) return "";
  if (!delLine.trim()) return `<div class="wb-ins">${renderMd(insLine)}</div>`;
  if (!insLine.trim()) return `<div class="wb-del">${renderMd(delLine)}</div>`;
  const source = mergeFlatListSource(delLine, insLine, detail) ??
    mergeInlineSource(delLine, insLine, detail);
  if (source === null)
    return `<div class="wb-del">${renderMd(delLine)}</div><div class="wb-ins">${renderMd(insLine)}</div>`;
  return `<div class="wb-mod">${renderMd(source)}</div>`;
}

function renderChangedLines(lines, cls, renderMd) {
  if (!lines.some((line) => line.trim())) return "";
  return `<div class="${cls}">${renderMd(lines.join(""))}</div>`;
}

// Emit a modification region (a deleted run directly followed by an inserted
// run, or vice versa): pair the lines word-by-word, then handle any leftover
// purely-inserted or purely-deleted lines.
function emitMod(dels, inss, renderMd, out, detail) {
  const pairs = Math.min(dels.length, inss.length);
  for (let k = 0; k < pairs; k++)
    out.push(renderPair(dels[k], inss[k], renderMd, detail));
  const removed = renderChangedLines(dels.slice(pairs), "wb-del", renderMd);
  const added = renderChangedLines(inss.slice(pairs), "wb-ins", renderMd);
  if (removed) out.push(removed);
  if (added) out.push(added);
}

export function renderWordDiff(oldContent, newContent, renderMd, {
  detail = "adaptive",
  markdownLexer = globalThis.marked?.lexer?.bind(globalThis.marked),
} = {}) {
  const oldText = String(oldContent ?? ""), newText = String(newContent ?? "");
  const sameProse = !hasMarkdownSyntax(oldText) && !hasMarkdownSyntax(newText) &&
    oldText.replace(/\s+/gu, " ").trim() === newText.replace(/\s+/gu, " ").trim();
  if (sameProse) return renderMd(newText);
  const ops = lineLcsOps(
    markdownUnits(oldText, markdownLexer),
    markdownUnits(newText, markdownLexer),
  );
  const out = [];
  let i = 0;
  while (i < ops.length) {
    const op = ops[i];
    if (op.t === "eq") {
      const lines = [];
      while (i < ops.length && ops[i].t === "eq") lines.push(ops[i].line), i++;
      if (lines.some((l) => l.trim() !== "")) out.push(renderMd(lines.join("")));
      continue;
    }
    if (op.t === "del") {
      const dels = [];
      while (i < ops.length && ops[i].t === "del") dels.push(ops[i].line), i++;
      const inss = [];
      while (i < ops.length && ops[i].t === "ins") inss.push(ops[i].line), i++;
      if (inss.length) emitMod(dels, inss, renderMd, out, detail);
      else {
        const removed = renderChangedLines(dels, "wb-del", renderMd);
        if (removed) out.push(removed);
      }
      continue;
    }
    // op.t === "ins" — collect the ins run, then any immediately-following del
    // run, and treat the pair as a modification (ins-then-del order).
    const inss = [];
    while (i < ops.length && ops[i].t === "ins") inss.push(ops[i].line), i++;
    const dels = [];
    while (i < ops.length && ops[i].t === "del") dels.push(ops[i].line), i++;
    if (dels.length) emitMod(dels, inss, renderMd, out, detail);
    else {
      const added = renderChangedLines(inss, "wb-ins", renderMd);
      if (added) out.push(added);
    }
  }
  return out.join("");
}
