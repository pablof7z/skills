// Markdown-safe inline diff helpers.
//
// Marked owns inline syntax recognition. Plain text is split into words while
// emphasis, code spans, links and other complete inline nodes stay atomic, so
// diff tags can wrap them without entering or corrupting their delimiters.

const SEGMENTER = typeof Intl !== "undefined" && typeof Intl.Segmenter === "function"
  ? new Intl.Segmenter(undefined, { granularity: "word" })
  : null;

function segmentedPieces(text) {
  const segments = SEGMENTER
    ? [...SEGMENTER.segment(text)].map(({ segment }) => segment)
    : [...String(text).matchAll(/(\s+|[\p{L}\p{N}\p{M}_]+|[^\s])/gu)].map((m) => m[0]);
  return segments.map((raw) => ({
    raw,
    key: `text\0${raw}`,
    measure: [...raw].length,
    ws: /^\s+$/u.test(raw),
  }));
}

function plainPieces(text) {
  const pieces = [], source = String(text);
  const entity = /&(?:#\d+|#[xX][\dA-Fa-f]+|[A-Za-z][A-Za-z\d]+);/g;
  let cursor = 0, match;
  while ((match = entity.exec(source))) {
    pieces.push(...segmentedPieces(source.slice(cursor, match.index)));
    pieces.push({ raw: match[0], key: `entity\0${match[0]}`, measure: 1, ws: false });
    cursor = match.index + match[0].length;
  }
  pieces.push(...segmentedPieces(source.slice(cursor)));
  return pieces;
}

function inlinePieces(source, lexer) {
  if (typeof lexer !== "function") return plainPieces(source);
  const pieces = [];
  for (const token of lexer(String(source))) {
    if (token.type === "text") {
      // Unparsed delimiters may be reference syntax whose definitions live at
      // document scope. Do not risk inserting tags into them without context.
      if (/[\\*~`\[\]<>]/u.test(token.raw)) return null;
      pieces.push(...plainPieces(token.raw));
      continue;
    }
    if (token.type === "html") return null;
    pieces.push({
      raw: token.raw,
      key: `markdown\0${token.type}\0${token.raw}`,
      measure: [...String(token.text ?? token.raw)].length,
      ws: false,
    });
  }
  return pieces;
}

function lcsOps(a, b) {
  const n = a.length, m = b.length;
  const dp = Array.from({ length: n + 1 }, () => new Array(m + 1).fill(0));
  for (let i = n - 1; i >= 0; i--)
    for (let j = m - 1; j >= 0; j--)
      dp[i][j] = a[i].key === b[j].key ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
  const ops = [];
  let i = 0, j = 0;
  while (i < n && j < m) {
    if (a[i].key === b[j].key) { ops.push({ t: "eq", piece: a[i] }); i++; j++; }
    else if (dp[i + 1][j] >= dp[i][j + 1]) { ops.push({ t: "del", piece: a[i++] }); }
    else { ops.push({ t: "ins", piece: b[j++] }); }
  }
  while (i < n) ops.push({ t: "del", piece: a[i++] });
  while (j < m) ops.push({ t: "ins", piece: b[j++] });
  return ops;
}

function isInlineEdit(ops, detail) {
  if (detail === "before-after") return false;
  const content = ops.filter((op) => !op.piece.ws);
  const chars = (type) => content
    .filter((op) => op.t === type)
    .reduce((sum, op) => sum + op.piece.measure, 0);
  const equal = chars("eq"), deleted = chars("del"), inserted = chars("ins");
  if (detail === "more-detail") return equal > 0;
  const changed = deleted + inserted;
  const similarity = (2 * equal) / Math.max(1, (2 * equal) + changed);
  let islands = 0, changing = false;
  for (const op of content) {
    if (op.t === "eq") { changing = false; continue; }
    if (!changing) { islands++; changing = true; }
  }
  // A long del/ins alternation between strong anchors is a rewrite, even when
  // the surrounding paragraph makes the global similarity look high.
  let churn = 0, maxChurn = 0, equalRun = 0, lastChange = null;
  for (const op of content) {
    if (op.t === "eq") {
      equalRun += op.piece.measure;
      if (equalRun >= 8) { churn = 0; lastChange = null; }
      continue;
    }
    equalRun = 0;
    if (op.t !== lastChange) churn++;
    lastChange = op.t;
    maxChurn = Math.max(maxChurn, churn);
  }
  if (maxChurn > 4) return false;
  return (islands === 1 && equal >= 4 && (changed <= 24 || similarity >= 0.45 || equal >= 18)) ||
    (similarity >= 0.6 && islands <= 4);
}

function splitPrefix(line) {
  const m = String(line).match(/^(\s{0,3}(?:#{1,6}\s+|> ?|(?:[-+*]|\d+[.)])\s+(?:\[[ xX]\]\s+)?))(.*)$/su);
  return m ? { prefix: m[1], body: m[2] } : { prefix: "", body: String(line) };
}

function hasBlockStructure(text) {
  if (/^(?: {4}|\t|\s{0,3}(?:```|~~~|\|))/m.test(text)) return true;
  return String(text).split("\n").slice(1).some((line) => !!splitPrefix(line).prefix);
}

function mergedSource(ops, prefix) {
  let source = prefix, run = null;
  const flush = () => {
    if (run) source += `<${run.tag}>${run.raw}</${run.tag}>`;
    run = null;
  };
  const nextContent = (index) => {
    for (let i = index + 1; i < ops.length; i++) if (!ops[i].piece.ws) return ops[i];
    return null;
  };
  for (let i = 0; i < ops.length; i++) {
    const op = ops[i], piece = op.piece;
    if (piece.ws) {
      const next = run && nextContent(i);
      if (next && next.t === run.t) run.raw += piece.raw;
      else { flush(); source += piece.raw; }
    } else if (op.t === "eq") {
      flush(); source += piece.raw;
    } else if (run?.t === op.t) {
      run.raw += piece.raw;
    } else {
      flush(); run = { t: op.t, tag: op.t === "del" ? "del" : "ins", raw: piece.raw };
    }
  }
  flush();
  return source;
}

export function mergeInlineSource(oldSource, newSource, detail, inlineLexer) {
  const oldPart = splitPrefix(oldSource), newPart = splitPrefix(newSource);
  if (oldPart.prefix !== newPart.prefix || hasBlockStructure(oldPart.body) || hasBlockStructure(newPart.body)) return null;
  const oldPieces = inlinePieces(oldPart.body, inlineLexer);
  const newPieces = inlinePieces(newPart.body, inlineLexer);
  if (!oldPieces || !newPieces) return null;
  const ops = lcsOps(oldPieces, newPieces);
  return isInlineEdit(ops, detail) ? mergedSource(ops, oldPart.prefix) : null;
}

export function hasMarkdownSyntax(text) {
  return /(?:^|\n)\s{0,3}(?:#{1,6}\s|> ?|[-+*]\s|\d+[.)]\s|```|~~~|\|)|[\\*~`\[\]<>]/u.test(String(text));
}
