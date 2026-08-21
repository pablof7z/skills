// TextQuoteSelector generation shared by CLI-created annotations. The viewer
// anchors against rendered Markdown textContent, so selectors must use that
// coordinate system rather than raw Markdown source offsets.

import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const { parse } = require("../viewer/vendor/marked.min.js");
const ENTITIES = { amp: "&", apos: "'", gt: ">", lt: "<", nbsp: "\u00a0", quot: '"' };

function decodeEntities(html) {
  return html.replace(/&(#x[\da-f]+|#\d+|\w+);/gi, (whole, entity) => {
    if (entity[0] !== "#") return ENTITIES[entity.toLowerCase()] ?? whole;
    const value = entity[1]?.toLowerCase() === "x" ? Number.parseInt(entity.slice(2), 16) : Number.parseInt(entity.slice(1), 10);
    return Number.isNaN(value) ? whole : String.fromCodePoint(value);
  });
}

// Marked is the same bundled renderer the browser loads. Its output retains
// whitespace text nodes between elements, so removing tags and decoding entities
// gives the DOM textContent coordinate system used by quoteMatch.
export function renderedText(md) {
  return decodeEntities(parse(String(md ?? "")).replace(/<[^>]*>/g, ""));
}

export function selectorFor(md, exact) {
  const plain = renderedText(md);
  const quote = renderedText(exact).trim();
  const i = plain.indexOf(quote);
  if (i === -1) throw new Error(`quote not found in block: "${String(exact).slice(0, 40)}…"`);
  return { exact: quote, prefix: i > 0 ? plain.slice(Math.max(0, i - 32), i) : "", suffix: plain.slice(i + quote.length, i + quote.length + 32) };
}
