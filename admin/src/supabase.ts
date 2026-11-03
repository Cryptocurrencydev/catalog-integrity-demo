import { createClient } from "@supabase/supabase-js";
import { SUPABASE_KEY, SUPABASE_URL } from "./config";

export const supabase = createClient(SUPABASE_URL, SUPABASE_KEY, {
  auth: { persistSession: true, autoRefreshToken: true },
});

/** Unwrap a PostgREST response; surface DB error codes (CI400, CI409...) to the UI. */
export async function must<T>(p: PromiseLike<{ data: T | null; error: { message: string; code?: string; details?: string } | null }>): Promise<T> {
  const { data, error } = await p;
  if (error) {
    const err = new Error(error.message) as Error & { code?: string; details?: string };
    err.code = error.code;
    err.details = error.details;
    throw err;
  }
  return data as T;
}
