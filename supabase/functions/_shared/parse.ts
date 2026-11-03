// Product-page extraction for brand sites. Dependency-free and deliberately
// defensive: brand sites put the INCI list in JSON-LD, accordions, spec
// tables or a bare "Ingredients:" paragraph. Strategies run in order.

export class ParseError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ParseError";
  }
}

export interface ParsedPage {
  brand: string;
  name: string;
  category: string;
  productType: string;
  ingredientsText: string;
  strategy: "json-ld" | "marked-element" | "heading";
}

const ENTITIES: Record<string, string> = {
  amp: "&",
  lt: "<",
  gt: ">",
  quot: '"',
  apos: "'",
  nbsp: " ",
  eacute: "é",
  egrave: "è",
  agrave: "à",
  ccedil: "ç",
  ndash: "–",
  mdash: "—",
  rsquo: "’",
  lsquo: "‘",
  middot: "·",
  bull: "•",
};

export function decodeEntities(s: string): string {
  return s.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (m, e: string) => {
    if (e[0] === "#") {
      const code = e[1] === "x" || e[1] === "X" ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10);
      return Number.isFinite(code) ? String.fromCodePoint(code) : m;
    }
    return ENTITIES[e.toLowerCase()] ?? m;
  });
}

/** HTML fragment -> text. List items and block elements become line/comma breaks. */
export function htmlToText(html: string): string {
  const withBreaks = html
    .replace(/<(script|style)[\s\S]*?<\/\1>/gi, "")
    .replace(/<\/li>\s*/gi, ", ")
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<\/(p|div|section|tr|dd|dt|h[1-6]|summary)>/gi, "\n")
    .replace(/<[^>]+>/g, "");
  return decodeEntities(withBreaks)
    .split("\n")
    .map((l) => l.replace(/[ \t]+/g, " ").trim())
    .filter(Boolean)
    .join("\n");
}

/** Inner HTML of the element whose opening tag starts at `openIdx`, nesting-aware. */
function elementInner(html: string, openIdx: number): string | null {
  const open = /^<([a-z0-9]+)\b[^>]*>/i.exec(html.slice(openIdx));
  if (!open) return null;
  const tag = open[1].toLowerCase();
  const re = new RegExp(`<(/?)${tag}\\b[^>]*>`, "gi");
  re.lastIndex = openIdx + open[0].length;
  let depth = 1;
  let m: RegExpExecArray | null;
  while ((m = re.exec(html))) {
    depth += m[1] ? -1 : 1;
    if (depth === 0) return html.slice(openIdx + open[0].length, m.index);
  }
  return null;
}

function meta(html: string, key: string): string | null {
  const re = new RegExp(
    `<meta[^>]+(?:property|name)=["']${key.replace(/[:.]/g, "\\$&")}["'][^>]*content=["']([^"']*)["']`,
    "i",
  );
  const m = re.exec(html);
  return m ? decodeEntities(m[1]).trim() : null;
}

function jsonLdProducts(html: string): Record<string, unknown>[] {
  const out: Record<string, unknown>[] = [];
  const re = /<script[^>]+type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi;
  let m: RegExpExecArray | null;
  while ((m = re.exec(html))) {
    try {
      const data = JSON.parse(m[1]);
      const items = Array.isArray(data) ? data : data["@graph"] ?? [data];
      for (const it of items) if (it && it["@type"] === "Product") out.push(it);
    } catch {
      // malformed JSON-LD is common; fall through to other strategies
    }
  }
  return out;
}

const TYPE_RULES: [RegExp, string, string][] = [
  [/spf|sunscreen|sun (lotion|fluid|cream)/i, "suncare", "sunscreen"],
  [/shampoo/i, "haircare", "shampoo"],
  [/conditioner|hair mask|masque|leave-in|curl/i, "haircare", "conditioner"],
  [/scalp/i, "haircare", "scalp"],
  [/body wash|shower gel/i, "bodycare", "body_wash"],
  [/body (lotion|cream|butter)|hand cream/i, "bodycare", "body_lotion"],
  [/lip/i, "bodycare", "lip_balm"],
  [/cleanser|face wash|cleansing/i, "skincare", "cleanser"],
  [/serum|essence|toner|tonic/i, "skincare", "serum"],
  [/cream|moisturi[sz]er|lotion|gel|mask|balm/i, "skincare", "moisturizer"],
];

export function classify(name: string): { category: string; productType: string } {
  for (const [re, category, productType] of TYPE_RULES) {
    if (re.test(name)) return { category, productType };
  }
  return { category: "skincare", productType: "unknown" };
}

export function parseProductPage(html: string): ParsedPage {
  const products = jsonLdProducts(html);
  const ld = products[0] as Record<string, any> | undefined;

  const h1 = /<h1[^>]*>([\s\S]*?)<\/h1>/i.exec(html);
  const name = (ld?.name as string | undefined)?.trim() ||
    meta(html, "og:title") ||
    (h1 ? htmlToText(h1[1]) : null);
  const brandRaw = ld?.brand;
  const brand = (typeof brandRaw === "string" ? brandRaw : brandRaw?.name)?.trim() ||
    meta(html, "product:brand") ||
    meta(html, "og:site_name");
  if (!name) throw new ParseError("no product name found");
  if (!brand) throw new ParseError("no brand found");

  let ingredientsText: string | null = null;
  let strategy: ParsedPage["strategy"] = "json-ld";

  // 1. JSON-LD additionalProperty { name: "Ingredients", value: "..." }
  const props = Array.isArray(ld?.additionalProperty) ? ld!.additionalProperty : [];
  const prop = props.find((p: any) => /ingredient|inci/i.test(String(p?.name ?? "")));
  if (prop?.value) ingredientsText = decodeEntities(String(prop.value));

  // 2. An element marked as the ingredient list (data attribute, id or class).
  if (!ingredientsText) {
    const marked = /<([a-z0-9]+)\b[^>]*(?:data-ingredients|(?:id|class)=["'][^"']*(?:ingredient|inci)[^"']*["'])[^>]*>/i
      .exec(html);
    if (marked) {
      const inner = elementInner(html, marked.index);
      if (inner) {
        const text = htmlToText(inner).replace(/^(full\s+)?ingredients?(\s+list)?\s*:?\s*$/im, "");
        if (text.trim()) {
          ingredientsText = text;
          strategy = "marked-element";
        }
      }
    }
  }

  // 3. A heading / summary / table header saying "Ingredients", then its content.
  if (!ingredientsText) {
    const head =
      /<(h[2-6]|summary|dt|th|strong|button)\b[^>]*>\s*(?:full\s+)?(?:ingredients?|inci)(?:\s+list)?\s*:?\s*<\/\1>/i
        .exec(html);
    if (head) {
      const after = html.slice(head.index + head[0].length);
      const block = /<(p|div|ul|ol|td|dd|span)\b[^>]*>/i.exec(after);
      if (block) {
        const inner = elementInner(after, block.index);
        if (inner && htmlToText(inner).trim()) {
          ingredientsText = htmlToText(inner);
          strategy = "heading";
        }
      }
    }
  }

  if (!ingredientsText || ingredientsText.trim().length < 3) {
    throw new ParseError("no ingredient list found on page");
  }
  const { category, productType } = classify(name);
  return { brand, name: decodeEntities(name), category, productType, ingredientsText, strategy };
}
