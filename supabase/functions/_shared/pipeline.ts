// Ingest pipeline: rate limit -> fetch (retry/backoff) -> parse -> split +
// normalise + dedupe -> alias matching -> transactional apply in Postgres.
// Every failure ends either in a typed result or in the dead-letter table.
// All I/O is injected (see PipelineDeps) so the routing is unit-testable.

import { dedupeByNormalized, normalizeInci, splitInciList } from "./inci.ts";
import { ParseError, parseProductPage } from "./parse.ts";
import { PermanentError, RetryableError, RetryExhaustedError, withRetry } from "./retry.ts";

export interface TokenResult {
  allowed: boolean;
  reason?: "unknown_source" | "blocked" | "rate_limited";
  retry_after_ms?: number;
  source_id?: number;
  trust_level?: string;
}

export interface NameResolution {
  idx: number;
  raw_name: string;
  normalized: string | null;
  match_kind: "canonical" | "alias" | "derived" | "fuzzy" | "none";
  ingredient_id: number | null;
  suggested_ingredient_id: number | null;
  inci_name: string | null;
  similarity: number | null;
  confidence: number;
  accepted: boolean;
}

export interface ApplyEntry {
  raw_name: string;
  normalized: string | null;
  ingredient_id: number | null;
  confidence: number;
  match_kind: NameResolution["match_kind"];
  suggested_ingredient_id: number | null;
  similarity: number | null;
  optional: boolean;
}

export interface ApplyPayload {
  url: string;
  source_domain: string;
  content_hash: string;
  product: { brand: string; name: string; category: string; product_type: string };
  ingredients: ApplyEntry[];
}

export interface CatalogDb {
  takeToken(domain: string): Promise<TokenResult>;
  resolveNames(names: string[]): Promise<NameResolution[]>;
  applyPage(payload: ApplyPayload): Promise<Record<string, unknown>>;
  recordFailure(f: {
    url: string;
    domain: string;
    stage: "rate_limit" | "fetch" | "parse" | "apply";
    error: string;
    httpStatus?: number;
    payload?: Record<string, unknown>;
  }): Promise<Record<string, unknown>>;
}

export interface FetchResponse {
  status: number;
  body: string;
}

export interface PipelineDeps {
  db: CatalogDb;
  fetchPage: (url: string) => Promise<FetchResponse>;
  sleep: (ms: number) => Promise<void>;
  random: () => number;
  log?: (event: string, data: Record<string, unknown>) => void;
}

export interface PipelineOptions {
  attempts: number;
  baseDelayMs: number;
  maxDelayMs: number;
}

export const DEFAULT_OPTIONS: PipelineOptions = { attempts: 3, baseDelayMs: 400, maxDelayMs: 5_000 };

export type IngestResult =
  | { status: "rejected"; url: string; reason: string }
  | { status: "rate_limited"; url: string; retryAfterMs: number }
  | {
    status: "dead_lettered";
    url: string;
    stage: string;
    error: string;
    attempts: number;
    deadLetter: Record<string, unknown>;
  }
  | {
    status: "applied" | "unchanged" | "held_for_verification" | "drafted";
    url: string;
    attempts: number;
    parsed: { name: string; brand: string; strategy: string; tokens: number; duplicatesDropped: number };
    db: Record<string, unknown>;
  };

export async function sha256Hex(text: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** Pure step: label tokens + DB resolutions -> ordered, de-duplicated apply entries. */
export function buildEntries(
  tokens: { raw: string; optional: boolean; normalized: string | null }[],
  resolutions: NameResolution[],
): { entries: ApplyEntry[]; duplicatesDropped: number } {
  const seenIds = new Set<number>();
  const entries: ApplyEntry[] = [];
  let duplicatesDropped = 0;
  tokens.forEach((t, i) => {
    const r = resolutions[i];
    const id = r?.accepted ? r.ingredient_id : null;
    if (id != null) {
      // "Aqua" and "Water" on the same label resolve to one ingredient: keep the first.
      if (seenIds.has(id)) {
        duplicatesDropped++;
        return;
      }
      seenIds.add(id);
    }
    entries.push({
      raw_name: t.raw,
      normalized: t.normalized,
      ingredient_id: id,
      confidence: r?.confidence ?? 0,
      match_kind: r?.match_kind ?? "none",
      suggested_ingredient_id: r?.suggested_ingredient_id ?? (r && !r.accepted ? r.ingredient_id : null),
      similarity: r?.similarity ?? null,
      optional: t.optional,
    });
  });
  return { entries, duplicatesDropped };
}

export async function ingestUrl(
  deps: PipelineDeps,
  url: string,
  options: PipelineOptions = DEFAULT_OPTIONS,
): Promise<IngestResult> {
  const log = deps.log ?? (() => {});
  let parsedUrl: URL;
  try {
    parsedUrl = new URL(url);
  } catch {
    return { status: "rejected", url, reason: "invalid_url" };
  }
  if (parsedUrl.protocol !== "https:") return { status: "rejected", url, reason: "https_required" };
  const domain = parsedUrl.hostname.toLowerCase();

  // 1. per-source rate limit (atomic in Postgres, shared by all workers)
  const token = await deps.db.takeToken(domain);
  if (!token.allowed) {
    if (token.reason === "rate_limited") {
      log("rate_limited", { url, retryAfterMs: token.retry_after_ms });
      return { status: "rate_limited", url, retryAfterMs: token.retry_after_ms ?? 60_000 };
    }
    return { status: "rejected", url, reason: token.reason ?? "not_allowed" };
  }

  const deadLetter = async (
    stage: "fetch" | "parse" | "apply",
    error: string,
    attempts: number,
    httpStatus?: number,
  ): Promise<IngestResult> => {
    const dl = await deps.db.recordFailure({ url, domain, stage, error, httpStatus, payload: { attempts } });
    log("dead_lettered", { url, stage, error, attempts });
    return { status: "dead_lettered", url, stage, error, attempts, deadLetter: dl };
  };

  // 2. fetch with retries (5xx / 429 / network -> retry; other 4xx -> permanent)
  let html: string;
  let attempts: number;
  try {
    const res = await withRetry(async () => {
      let r: FetchResponse;
      try {
        r = await deps.fetchPage(url);
      } catch (e) {
        throw new RetryableError(`network: ${e instanceof Error ? e.message : String(e)}`);
      }
      if (r.status === 429 || r.status >= 500) throw new RetryableError(`http ${r.status}`, r.status);
      if (r.status >= 400) throw new PermanentError(`http ${r.status}`, r.status);
      return r.body;
    }, {
      ...options,
      sleep: deps.sleep,
      random: deps.random,
      onRetry: (attempt, delayMs, err) => log("retry", { url, attempt, delayMs, error: String(err) }),
    });
    html = res.value;
    attempts = res.attempts;
  } catch (e) {
    if (e instanceof RetryExhaustedError) return deadLetter("fetch", e.message, e.attempts, e.status);
    throw e;
  }

  // 3. parse + split + normalise + dedupe
  let page;
  try {
    page = parseProductPage(html);
  } catch (e) {
    if (e instanceof ParseError) return deadLetter("parse", e.message, attempts);
    throw e;
  }
  const rawTokens = splitInciList(page.ingredientsText).map((t) => ({ ...t, normalized: normalizeInci(t.raw) }));
  const tokens = dedupeByNormalized(rawTokens);
  if (tokens.length === 0) return deadLetter("parse", "ingredient list is empty after splitting", attempts);

  // 4. alias matching (canonical / alias / derived / fuzzy suggestion) in Postgres
  const resolutions = await deps.db.resolveNames(tokens.map((t) => t.raw));
  const { entries, duplicatesDropped } = buildEntries(tokens, resolutions);

  const contentHash = await sha256Hex(JSON.stringify({
    brand: page.brand,
    name: page.name,
    names: tokens.map((t) => t.normalized),
  }));

  // 5. transactional apply: catalog via repair RPC, or queue / draft
  const payload: ApplyPayload = {
    url,
    source_domain: domain,
    content_hash: contentHash,
    product: { brand: page.brand, name: page.name, category: page.category, product_type: page.productType },
    ingredients: entries,
  };
  let result: Record<string, unknown>;
  try {
    result = await deps.db.applyPage(payload);
  } catch (e) {
    return deadLetter("apply", e instanceof Error ? e.message : String(e), attempts);
  }
  const status = String(result.status ?? "applied") as "applied" | "unchanged" | "held_for_verification" | "drafted";
  log("ingested", { url, status, productId: result.product_id });
  return {
    status,
    url,
    attempts,
    parsed: {
      name: page.name,
      brand: page.brand,
      strategy: page.strategy,
      tokens: rawTokens.length,
      duplicatesDropped: duplicatesDropped + (rawTokens.length - tokens.length),
    },
    db: result,
  };
}
