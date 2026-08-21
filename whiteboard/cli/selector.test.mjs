// Node self-test for CLI TextQuoteSelector generation.
// Run: node whiteboard/cli/selector.test.mjs
import { quoteIndex } from "../viewer/comments.mjs";
import { renderedText, selectorFor } from "./selector.mjs";

let pass = 0, fail = 0;
function eq(actual, expected, msg) {
  if (actual === expected) pass++;
  else { fail++; console.error(`FAIL ${msg}\n  want: ${JSON.stringify(expected)}\n  got: ${JSON.stringify(actual)}`); }
}

const md = "# Constraints\n\n- `Fava::publish(..)`\n- **UNDER REVISION (user + ../nmp prior art):** exact host set\n- next";
const selector = selectorFor(md, "UNDER REVISION (user + ../nmp prior art)");
eq(selector.prefix.includes("- "), false, "list marker is absent from rendered prefix");
eq(quoteIndex(renderedText(md), selector.exact, selector.prefix, selector.suffix) >= 0, true, "selector re-anchors in rendered text");

const listSelector = selectorFor(md, "- next");
eq(listSelector.exact, "next", "raw list syntax becomes the visible quote text");
eq(quoteIndex(renderedText(md), listSelector.exact, listSelector.prefix, listSelector.suffix) >= 0, true, "list-item selector re-anchors");

console.log(`${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
