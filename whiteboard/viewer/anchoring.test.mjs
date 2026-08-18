// Node self-test for the whitespace-flexible quote matcher in comments.mjs.
// The document's textContent keeps raw newlines/multi-space from block structure;
// a stored TextQuoteSelector.exact comes from a browser selection (collapsed
// spaces) or raw markdown. The matcher must find the quote without mutating
// either side, and report a real [start,end] span in the unmodified haystack.
// Run: node whiteboard/viewer/anchoring.test.mjs
import { quoteIndex, quoteMatch } from "./comments.mjs";

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

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);