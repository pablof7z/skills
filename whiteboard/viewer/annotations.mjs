// viewer/annotations.mjs — presentation palette for annotation kinds. The fold
// (cli/doc.mjs) is domain; this is viewer-only: how each `kind` renders (CSS class,
// icon, label). Color is the only signal — there is no `motivation` field and no
// separate "attention" concept. Unknown kinds fall back to "note".

export const KIND_STYLE = {
  question:         { cls: "k-question",       icon: "?",  label: "Question",   dot: "#3b82f6" },
  warning:          { cls: "k-warning",        icon: "⚠", label: "Warning",    dot: "#f59e0b" },
  objection:        { cls: "k-objection",       icon: "✕", label: "Objection",  dot: "#ef4444" },
  note:             { cls: "k-note",            icon: "·", label: "Note",       dot: "#9ca3af" },
  unverified:       { cls: "k-unverified",      icon: "?", label: "Unverified", dot: "#9ca3af" },
  superseded:       { cls: "k-superseded",      icon: "↳", label: "Superseded", dot: "#6b7280" },
  "needs-attention": { cls: "k-needs-attention", icon: "⚑", label: "Needs attention", dot: "#f59e0b" },
  decided:          { cls: "k-decided",         icon: "✓", label: "Decided",    dot: "#10b981" },
};

const FALLBACK = KIND_STYLE.note;
export const styleOf = (kind) => KIND_STYLE[kind] || FALLBACK;

// The kinds a human can author from the composer (the replyable threads).
export const COMPOSER_KINDS = ["question", "note", "objection", "warning"];