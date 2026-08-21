// Node self-test for the whitespace-flexible quote matcher in comments.mjs.
// The document's textContent keeps raw newlines/multi-space from block structure;
// a stored TextQuoteSelector.exact comes from a browser selection (collapsed
// spaces) or raw markdown. The matcher must find the quote without mutating
// either side, and report a real [start,end] span in the unmodified haystack.
// Run: node whiteboard/viewer/anchoring.test.mjs
import {
  anchorOffset,
  anchorText,
  normalizeAnchorSelector,
  quoteIndex,
  quoteMatch,
  relativeTop,
} from "./comments.mjs";

let pass = 0, fail = 0;
function eq(actual, expected, msg) {
  if (actual === expected) pass++;
  else { fail++; console.error(`FAIL ${msg}\n  want: ${JSON.stringify(expected)}\n  got:  ${JSON.stringify(actual)}`); }
}

// 1) exact with single spaces matches a haystack where the same words are split
//    by a newline (the live-demo regression: "live demo doc for" vs "live demo\ndoc for").
eq(quoteIndex("live demo\ndoc for X", "live demo doc for", "", ""), 0, "newline between words still matches at 0");

// 2) the matched span end covers the real haystack chars (newline counts), so
//    the highlight is not cut short.
eq(quoteMatch("live demo\ndoc for X", "live demo doc for", "", "").end, 17, "match end counts the newline, not a space");

// 3) multiple spaces in the haystack collapse-flexibly match a single space in exact.
eq(quoteIndex("a   b   c", "a b c", "", ""), 0, "multi-space haystack matches single-space exact");

// 4) prefix + exact + suffix with differing whitespace at the prefix/exact seam.
//    prefix "x " in the query, but haystack has "x\n" before the quote.
const r4 = quoteMatch("x\nlive demo doc for y", "live demo doc for", "x ", " y");
eq(r4 && r4.start, 2, "prefix with newline still locates exact start");
eq(r4 && r4.end, 2 + 17, "prefix branch end is exact start + exact span");

// 5) suffix-only: exact followed by a newline-then-suffix in the haystack.
eq(quoteIndex("live demo doc for\nzzz", "live demo doc for", "", " zzz"), 0, "suffix with newline matches");

// 6) genuinely absent quote returns -1.
eq(quoteIndex("nothing like this here", "live demo doc for", "", ""), -1, "absent quote returns -1");

// 7) regex-special characters in the quote are escaped, not interpreted.
eq(quoteIndex("cost ($5) today", "cost ($5)", "", ""), 0, "parens/dollar in exact are literal");

// 8) regex metachars in prefix/suffix are literal too.
eq(quoteIndex("a.b.c end", "b", "a.", ".c end"), 2, "dots in prefix/suffix are literal");

// 9) exact containing internal whitespace run still matches a single-space haystack.
eq(quoteIndex("live demo doc for", "live  demo doc for", "", ""), 0, "exact multi-space matches single-space haystack");

// 10) empty exact never matches.
eq(quoteIndex("anything", "", "", ""), -1, "empty exact returns -1");

// 11) a stale viewer-control glyph in one side of the stored context must not
// make an otherwise well-disambiguated quote stale. This is the fullscreen
// button regression that made comments after code blocks appear Unanchored.
const repeated = "code output\nDiscovery\nGroups I've saved\nDiscovery is useful";
const recovered = quoteMatch(repeated, "Discovery", "code output\n⤢\n", "\nGroups I've saved");
eq(recovered && recovered.start, 12, "matching suffix recovers an anchor with stale UI text in its prefix");

// 12) the canonical anchor-text projection excludes viewer controls while
// preserving offsets in visible document text.
const visibleA = { nodeValue: "before ", parentElement: { closest: () => null } };
const control = { nodeValue: "⤢", parentElement: { closest: () => ({}) } };
const visibleB = { nodeValue: "Discovery", parentElement: { closest: () => null } };
const nodes = [visibleA, control, visibleB];
const fakeRoot = {
  querySelectorAll: () => [{ textContent: "⤢" }],
  ownerDocument: {
    defaultView: { NodeFilter: { SHOW_TEXT: 4 } },
    createTreeWalker: () => {
      let i = 0;
      return { nextNode: () => nodes[i++] || null };
    },
  },
};
eq(anchorText(fakeRoot), "before Discovery", "viewer-only control text is absent from anchor text");
eq(anchorOffset(fakeRoot, visibleB, 4), 11, "anchor offsets use the same control-free projection");
eq(
  normalizeAnchorSelector(fakeRoot, { exact: "Discovery", prefix: "before ⤢ ", suffix: " after" }).prefix,
  "before  ",
  "legacy selector context drops text from controls now marked anchor-ignored",
);

// 13) rail coordinates are geometry-relative, independent of offsetParent.
eq(relativeTop({ top: 442 }, { top: 100 }), 342, "selection top is measured relative to the comment rail");

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
