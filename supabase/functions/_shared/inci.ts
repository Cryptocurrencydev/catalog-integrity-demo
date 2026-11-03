// INCI label handling: normalisation (mirrors public.normalize_inci in SQL)
// and splitting a raw label string into ordered ingredient tokens.

const FROM = "   ‐‑‒–—―’‘´`" +
  "àáâäãåèéêëìíîïòóôöõùúûüçñÀÁÂÄÃÅÈÉÊËÌÍÎÏÒÓÔÖÕÙÚÛÜÇÑ";
const TO = "   ------''''" + "aaaaaaeeeeiiiiooooouuuucn" + "aaaaaaeeeeiiiiooooouuuucn";
const DROP = new Set(["*", "†", "‡", "°", "^", "¹", "²", "³"]);
const MAP = new Map<string, string>([...FROM].map((c, i) => [c, TO[i]]));

/** Canonical comparison key. Must stay byte-identical to public.normalize_inci(). */
export function normalizeInci(name: string | null | undefined): string | null {
  if (name == null) return null;
  let out = "";
  for (const ch of name.toLowerCase()) {
    if (DROP.has(ch)) continue;
    out += MAP.get(ch) ?? ch;
  }
  out = out
    .replace(/[ \t\n\r\f\v]*([/,-])[ \t\n\r\f\v]*/g, "$1")
    .replace(/sulph/g, "sulf")
    .replace(/[ \t\n\r\f\v]+/g, " ")
    .replace(/^[ \t\n\r\f\v.,;:]+/, "")
    .replace(/[ \t\n\r\f\v.,;:]+$/, "");
  return out === "" ? null : out;
}

export interface LabelToken {
  raw: string;
  /** Listed after "May contain (+/-)": colour shades, optional per batch. */
  optional: boolean;
}

const LABEL_PREFIX = /^\s*(full\s+)?(ingredients?|inci|composition)(\s+list)?\s*[:\-–]\s*/i;
const MAY_CONTAIN =
  /may\s+contain\s*(?:\(\s*\+\/-\s*\)|\[\s*\+\/-\s*\])?\s*:?|(?:\(\s*\+\/-\s*\)|\[\s*\+\/-\s*\])\s*:?/i;

/**
 * Split a label ingredient string into ordered tokens.
 * - commas / semicolons / bullets at bracket depth 0 separate ingredients
 * - a comma between digits ("1,2-Hexanediol") is part of the name
 * - footnote lines ("*Certified organic") are dropped
 * - everything after "May contain (+/-)" is flagged optional
 */
export function splitInciList(text: string): LabelToken[] {
  const lines = text
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter((l) => l !== "" && !/^[*†‡]/.test(l));
  let body = lines.join(" ").replace(LABEL_PREFIX, "");

  let optionalFrom = -1;
  const m = MAY_CONTAIN.exec(body);
  if (m) {
    optionalFrom = m.index;
    body = body.slice(0, m.index) + "," + body.slice(m.index + m[0].length);
  }

  const tokens: LabelToken[] = [];
  let depth = 0;
  let current = "";
  let start = 0;
  const flush = (end: number) => {
    const raw = current.trim().replace(/^[.,;:\s]+|[.,;:\s]+$/g, "").replace(/\s+/g, " ");
    if (raw !== "") tokens.push({ raw, optional: optionalFrom >= 0 && start >= optionalFrom });
    current = "";
    start = end + 1;
  };
  for (let i = 0; i < body.length; i++) {
    const ch = body[i];
    if (ch === "(" || ch === "[") depth++;
    if ((ch === ")" || ch === "]") && depth > 0) depth--;
    const isSep = depth === 0 && (ch === ";" || ch === "•" || ch === "·" || ch === "|" ||
      (ch === "," && !(/\d/.test(body[i - 1] ?? "") && /\d/.test(body[i + 1] ?? ""))));
    if (isSep) flush(i);
    else current += ch;
  }
  flush(body.length);
  return tokens;
}

/** Keep the first occurrence of each normalised name (label order is meaningful). */
export function dedupeByNormalized<T extends { normalized: string | null }>(items: T[]): T[] {
  const seen = new Set<string>();
  return items.filter((it) => {
    if (it.normalized == null || seen.has(it.normalized)) return false;
    seen.add(it.normalized);
    return true;
  });
}
