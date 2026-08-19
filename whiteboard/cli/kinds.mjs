// kinds.mjs — the annotation kind vocabulary, shared by the fold (doc.mjs),
// the CLI (annotations.mjs / main.mjs), scan.mjs, the viewer server
// (lib/blockdoc.mjs), and the pi extension. Presentation (color/icon/label) is
// viewer-side; this module is domain only: which kinds exist, which are
// conversational threads vs short status tags, and how legacy kinds map.
//
// Two verbs share one storage primitive (an `attach` op with a `kind`):
//   wb attach <block> --on "…" --kind <attach-kind> --content T
//      attach kinds are replyable + resolvable (a conversation about the doc).
//   wb tag   <block> --on "…" --kind <tag-kind>   [--content T]
//      tag kinds are idempotent status markers you set and clear (no replies).
// Every annotation is anchored to a text span (--on); there are no block-level
// annotations.

export const ATTACH_KINDS = ["question", "warning", "objection", "note"];
export const TAG_KINDS = ["unverified", "superseded", "needs-attention", "decided"];
export const ALL_KINDS = [...ATTACH_KINDS, ...TAG_KINDS];
// Thread kinds that demand an agent reply (wake the agent when a user authors one
// with no agent reply). `note` is a non-action side comment and does NOT wake.
export const ACTIONABLE_KINDS = ["question", "warning", "objection"];

const ATTACH = new Set(ATTACH_KINDS);
const TAG = new Set(TAG_KINDS);
const ALL = new Set(ALL_KINDS);
const ACTIONABLE = new Set(ACTIONABLE_KINDS);

export const isAttachKind = (k) => ATTACH.has(k);
export const isTagKind = (k) => TAG.has(k);
export const isKnownKind = (k) => ALL.has(k);
export const isActionableKind = (k) => ACTIONABLE.has(k);

// Legacy kinds written by the old comment/flag/attention commands, mapped to
// the new vocabulary at fold-projection time (history is append-only; we never
// rewrite change files). "comment" was a generic replyable note; a needs-attention
// created with motivation:"highlighting" was really a tag; plain label flags
// (decided/superseded/…) already use tag-kind names and pass through unchanged.
export const LEGACY_KIND_MAP = { comment: "note" };

export function resolveKind(kind, motivation) {
  if (motivation === "highlighting") return "needs-attention"; // old `wb change attention`
  const mapped = LEGACY_KIND_MAP[kind] || kind;
  return isKnownKind(mapped) ? mapped : "note"; // unknown legacy kind → note
}

// Assert a kind is valid for the `wb attach` verb (replyable thread).
export function requireAttachKind(kind) {
  if (!isAttachKind(kind)) throw new Error(`invalid attach kind "${kind}" (one of ${ATTACH_KINDS.join(", ")})`);
  return kind;
}

// Assert a kind is valid for the `wb tag` verb (status marker).
export function requireTagKind(kind) {
  if (!isTagKind(kind)) throw new Error(`invalid tag kind "${kind}" (one of ${TAG_KINDS.join(", ")})`);
  return kind;
}