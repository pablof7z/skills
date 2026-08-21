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

import { hasMarkdownSyntax, mergeInlineSource } from "./inlinediff.mjs";

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

const SENTENCE_SEGMENTER = typeof Intl !== "undefined" && typeof Intl.Segmenter === "function"
  ? new Intl.Segmenter(undefined, { granularity: "sentence" })
  : null;

function sentenceUnits(text) {
  if (!SENTENCE_SEGMENTER) return [];
  return [...SENTENCE_SEGMENTER.segment(String(text).trim())]
    .map(({ segment }) => ({ raw: segment, key: segment.trim() }));
}

function flatListItems(text) {
  const lines = String(text).trimEnd().split("\n");
  if (lines.length < 2) return null;
  const items = lines.map((line) => {
    const match = line.match(/^\s{0,3}([-+*]|\d+[.)])\s+(.*)$/su);
    if (!match) return null;
    const task = match[2].match(/^\[([ xX])\]\s+(.*)$/su);
    return {
      marker: match[1],
      body: task ? task[2] : match[2],
      task: !!task,
      checked: !!task && task[1].toLowerCase() === "x",
    };
  });
  return items.every(Boolean) ? items : null;
}

function inlineHtml(source, renderMd) {
  const html = renderMd(source).trim();
  const paragraph = html.match(/^<p>([\s\S]*)<\/p>$/u);
  return paragraph ? paragraph[1] : html;
}

// Preserve one list and its numbering while each item independently chooses
// inline detail or a sentence/item-level before-and-after rendering.
function renderFlatListDiff(oldText, newText, renderMd, detail, inlineLexer) {
  const oldItems = flatListItems(oldText), newItems = flatListItems(newText);
  if (!oldItems || !newItems || oldItems.length !== newItems.length) return null;
  const ordered = /^\d/u.test(newItems[0].marker);
  if (![...oldItems, ...newItems].every((item) => /^\d/u.test(item.marker) === ordered)) return null;
  if (newItems.some((item, index) => item.task !== oldItems[index].task ||
      item.checked !== oldItems[index].checked)) return null;
  const tag = ordered ? "ol" : "ul";
  const start = ordered ? ` start="${Number.parseInt(newItems[0].marker, 10)}"` : "";
  const rows = newItems.map((item, index) => {
    const old = oldItems[index];
    const task = item.task ? `<input${item.checked ? ' checked=""' : ""} disabled="" type="checkbox"> ` : "";
    if (old.body === item.body) return `<li>${task}${inlineHtml(item.body, renderMd)}</li>`;
    const source = mergeInlineSource(old.body, item.body, detail, inlineLexer);
    if (source !== null) return `<li>${task}${inlineHtml(source, renderMd)}</li>`;
    const sentences = renderSentenceDiff(old.body, item.body, renderMd, detail, inlineLexer);
    const change = sentences ?? `<div class="wb-del">${renderMd(old.body)}</div>` +
      `<div class="wb-ins">${renderMd(item.body)}</div>`;
    return `<li>${task}${change}</li>`;
  });
  return `<${tag}${start}>${rows.join("")}</${tag}>`;
}

// Render one paired deleted/inserted Markdown unit at useful granularity.
function renderPair(delLine, insLine, renderMd, detail, inlineLexer) {
  if (!delLine.trim() && !insLine.trim()) return "";
  if (!delLine.trim()) return `<div class="wb-ins">${renderMd(insLine)}</div>`;
  if (!insLine.trim()) return `<div class="wb-del">${renderMd(delLine)}</div>`;
  const list = renderFlatListDiff(delLine, insLine, renderMd, detail, inlineLexer);
  if (list !== null) return `<div class="wb-mod">${list}</div>`;
  const source = mergeInlineSource(delLine, insLine, detail, inlineLexer);
  if (source === null) {
    const sentences = renderSentenceDiff(delLine, insLine, renderMd, detail, inlineLexer);
    if (sentences !== null) return sentences;
    return `<div class="wb-del">${renderMd(delLine)}</div><div class="wb-ins">${renderMd(insLine)}</div>`;
  }
  return `<div class="wb-mod">${renderMd(source)}</div>`;
}

function renderChangedLines(lines, cls, renderMd) {
  if (!lines.some((line) => line.trim())) return "";
  return `<div class="${cls}">${renderMd(lines.join(""))}</div>`;
}

function renderSentencePair(oldSentence, newSentence, renderMd, detail, inlineLexer) {
  const source = mergeInlineSource(oldSentence, newSentence, detail, inlineLexer);
  if (source !== null) return `<div class="wb-mod">${renderMd(source)}</div>`;
  return `<div class="wb-del">${renderMd(oldSentence)}</div>` +
    `<div class="wb-ins">${renderMd(newSentence)}</div>`;
}

// When a paragraph contains one rewritten sentence, keep exact surrounding
// sentences as context and stack only the rewrite. This prevents word-level
// "confetti" without promoting the entire paragraph to before/after blocks.
function renderSentenceDiff(oldText, newText, renderMd, detail, inlineLexer) {
  const block = /^(?: {4}|\t|\s{0,3}(?:#{1,6}\s|> ?|[-+*]\s|\d+[.)]\s|```|~~~|\|))/m;
  if (block.test(oldText) || block.test(newText)) return null;
  const oldUnits = sentenceUnits(oldText), newUnits = sentenceUnits(newText);
  if (Math.max(oldUnits.length, newUnits.length) < 2) return null;
  const ops = lineLcsOps(oldUnits, newUnits);
  if (!ops.some((op) => op.t === "eq")) return null;
  const out = [];
  let i = 0;
  while (i < ops.length) {
    if (ops[i].t === "eq") {
      const same = [];
      while (i < ops.length && ops[i].t === "eq") same.push(ops[i++].line);
      out.push(renderMd(same.join("")));
      continue;
    }
    const first = ops[i].t, firstLines = [];
    while (i < ops.length && ops[i].t === first) firstLines.push(ops[i++].line);
    const secondLines = [];
    if (i < ops.length && ops[i].t !== "eq" && ops[i].t !== first) {
      const second = ops[i].t;
      while (i < ops.length && ops[i].t === second) secondLines.push(ops[i++].line);
    }
    const dels = first === "del" ? firstLines : secondLines;
    const inss = first === "ins" ? firstLines : secondLines;
    const pairs = Math.min(dels.length, inss.length);
    for (let k = 0; k < pairs; k++)
      out.push(renderSentencePair(dels[k], inss[k], renderMd, detail, inlineLexer));
    const removed = renderChangedLines(dels.slice(pairs), "wb-del", renderMd);
    const added = renderChangedLines(inss.slice(pairs), "wb-ins", renderMd);
    if (removed) out.push(removed);
    if (added) out.push(added);
  }
  return out.join("");
}

// Emit a modification region (a deleted run directly followed by an inserted
// run, or vice versa): pair the lines word-by-word, then handle any leftover
// purely-inserted or purely-deleted lines.
function emitMod(dels, inss, renderMd, out, detail, inlineLexer) {
  const pairs = Math.min(dels.length, inss.length);
  for (let k = 0; k < pairs; k++)
    out.push(renderPair(dels[k], inss[k], renderMd, detail, inlineLexer));
  const removed = renderChangedLines(dels.slice(pairs), "wb-del", renderMd);
  const added = renderChangedLines(inss.slice(pairs), "wb-ins", renderMd);
  if (removed) out.push(removed);
  if (added) out.push(added);
}

export function renderWordDiff(oldContent, newContent, renderMd, {
  detail = "adaptive",
  markdownLexer = globalThis.marked?.lexer?.bind(globalThis.marked),
  inlineLexer = globalThis.marked?.Lexer?.lexInline?.bind(globalThis.marked.Lexer),
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
      if (inss.length) emitMod(dels, inss, renderMd, out, detail, inlineLexer);
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
    if (dels.length) emitMod(dels, inss, renderMd, out, detail, inlineLexer);
    else {
      const added = renderChangedLines(inss, "wb-ins", renderMd);
      if (added) out.push(added);
    }
  }
  return out.join("");
}
