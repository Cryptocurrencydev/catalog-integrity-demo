// Public client config. The publishable key is designed to ship to browsers:
// every table is behind RLS and every write goes through admin-checked RPCs.
export const SUPABASE_URL = import.meta.env.VITE_SUPABASE_URL ?? "https://tvvctzhlizksrdqbqryb.supabase.co";
export const SUPABASE_KEY = import.meta.env.VITE_SUPABASE_KEY ?? "sb_publishable_0fFsPv2Itv6Y1O7hYFCH3w_THNh3gtY";
export const DEMO_EMAIL = "admin@catalog-demo.example";
export const DEMO_PASSWORD = "catalog-demo-2026";
