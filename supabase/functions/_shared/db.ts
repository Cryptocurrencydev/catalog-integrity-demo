// CatalogDb backed by supabase-js RPCs (service role).
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.45.4";
import type { ApplyPayload, CatalogDb, NameResolution, TokenResult } from "./pipeline.ts";

export class DbError extends Error {
  constructor(message: string, readonly code?: string) {
    super(message);
    this.name = "DbError";
  }
}

export function supabaseCatalogDb(client: SupabaseClient): CatalogDb {
  const rpc = async <T>(fn: string, args: Record<string, unknown>): Promise<T> => {
    const { data, error } = await client.rpc(fn, args);
    if (error) throw new DbError(`${fn}: ${error.message}${error.details ? ` (${error.details})` : ""}`, error.code);
    return data as T;
  };
  return {
    takeToken: (domain) => rpc<TokenResult>("ingest_take_token", { p_domain: domain }),
    resolveNames: (names) => rpc<NameResolution[]>("resolve_ingredient_names", { p_names: names }),
    applyPage: (payload: ApplyPayload) => rpc<Record<string, unknown>>("ingest_apply_page", { p_page: payload }),
    recordFailure: (f) =>
      rpc<Record<string, unknown>>("ingest_record_failure", {
        p_url: f.url,
        p_domain: f.domain,
        p_stage: f.stage,
        p_error: f.error,
        p_http_status: f.httpStatus ?? null,
        p_payload: f.payload ?? {},
      }),
  };
}
