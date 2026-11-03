// POST /functions/v1/ingest-product-page
//   {"url": "https://..."}            ingest one page
//   {"urls": ["https://...", ...]}    ingest several (sequentially, rate limits apply)
//   {"mode": "retry_dead_letters"}    claim due dead letters and retry them
// Callers: the service role (workers/cron), or a signed-in admin (the demo UI's
// "Ingest" tab). verify_jwt is off so new-style secret keys work; auth is checked here.
// Whoever calls, the pipeline itself always runs with the service role.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { supabaseCatalogDb } from "../_shared/db.ts";
import { DEFAULT_OPTIONS, ingestUrl, type PipelineDeps } from "../_shared/pipeline.ts";
import { fixtureFetch } from "./fixtures.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ACCEPTED_KEYS = [SERVICE_KEY, Deno.env.get("SUPABASE_SECRET_KEY") ?? ""].filter(Boolean);

function timingSafeEqual(a: string, b: string): boolean {
  const ea = new TextEncoder().encode(a);
  const eb = new TextEncoder().encode(b);
  let diff = ea.length ^ eb.length;
  for (let i = 0; i < Math.max(ea.length, eb.length); i++) diff |= (ea[i] ?? 0) ^ (eb[i] ?? 0);
  return diff === 0;
}

const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, x-client-info, apikey, content-type",
  "access-control-allow-methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", ...CORS } });
}

async function callerKind(token: string): Promise<"service" | "admin" | null> {
  if (!token) return null;
  if (ACCEPTED_KEYS.some((k) => timingSafeEqual(token, k))) return "service";
  const { data, error } = await createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } })
    .auth.getUser(token);
  if (error || !data.user) return null;
  return data.user.app_metadata?.role === "admin" ? "admin" : null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  const caller = await callerKind(token);
  if (!caller) return json({ error: "service_role_or_admin_required" }, 401);

  let body: { url?: string; urls?: string[]; mode?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  const client = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });
  const deps: PipelineDeps = {
    db: supabaseCatalogDb(client),
    fetchPage: fixtureFetch,
    sleep: (ms) => new Promise((r) => setTimeout(r, ms)),
    random: Math.random,
    log: (event, data) => console.log(JSON.stringify({ event, ...data })),
  };

  if (caller === "admin" && (body.mode || (body.urls?.length ?? 0) > 10)) {
    return json({ error: "admins may ingest up to 10 urls per call" }, 403);
  }

  if (body.mode === "retry_dead_letters") {
    const { data, error } = await client.rpc("ingest_claim_dead_letters", { p_limit: 20 });
    if (error) return json({ error: error.message }, 500);
    const results = [];
    for (const row of data as { url: string }[]) results.push(await ingestUrl(deps, row.url, DEFAULT_OPTIONS));
    return json({ retried: results.length, results });
  }

  const urls = body.urls ?? (body.url ? [body.url] : []);
  if (urls.length === 0 || urls.length > 50) return json({ error: "pass url or 1-50 urls" }, 400);
  const results = [];
  for (const url of urls) results.push(await ingestUrl(deps, url, DEFAULT_OPTIONS));
  return json({ results });
});
