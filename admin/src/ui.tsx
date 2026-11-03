import { createContext, useCallback, useContext, useEffect, useRef, useState, type ReactNode } from "react";
import { supabase } from "./supabase";

export function timeAgo(iso: string): string {
  const s = Math.max(1, Math.round((Date.now() - new Date(iso).getTime()) / 1000));
  if (s < 60) return `${s}s ago`;
  const m = Math.round(s / 60);
  if (m < 60) return `${m}m ago`;
  const h = Math.round(m / 60);
  if (h < 48) return `${h}h ago`;
  return `${Math.round(h / 24)}d ago`;
}

export const fmt = (n: number | null | undefined) => (n == null ? "–" : n.toLocaleString("en-GB"));

const PROVENANCE: Record<string, string> = { verified: "ok", manual: "info", scraped: "", ai_suggested: "warn" };
export function Provenance({ kind }: { kind?: string | null }) {
  if (!kind) return null;
  return <span className={`chip ${PROVENANCE[kind] ?? ""}`}>{kind.replace("_", " ")}</span>;
}

export function Chip({ tone = "", children }: { tone?: string; children: ReactNode }) {
  return <span className={`chip ${tone}`}>{children}</span>;
}

/** Turn DB errors (CI400 detail JSON etc.) into a readable line. */
export function explainError(e: unknown): string {
  const err = e as { message?: string; code?: string; details?: string };
  let msg = err.message ?? String(e);
  if (err.details) {
    try {
      const d = JSON.parse(err.details);
      if (Array.isArray(d)) msg += ": " + d.map((p) => `#${p.position} ${p.error}${p.name ? ` (${p.name})` : ""}`).join(", ");
    } catch {
      msg += ` (${err.details})`;
    }
  }
  return err.code ? `${msg} [${err.code}]` : msg;
}

type Toast = { text: string; bad?: boolean } | null;
const ToastCtx = createContext<(text: string, bad?: boolean) => void>(() => {});
export const useToast = () => useContext(ToastCtx);

export function ToastProvider({ children }: { children: ReactNode }) {
  const [toast, setToast] = useState<Toast>(null);
  const timer = useRef<number>();
  const show = useCallback((text: string, bad = false) => {
    setToast({ text, bad });
    window.clearTimeout(timer.current);
    timer.current = window.setTimeout(() => setToast(null), bad ? 7000 : 4500);
  }, []);
  return (
    <ToastCtx.Provider value={show}>
      {children}
      {toast && <div role="status" className={`toast ${toast.bad ? "bad" : ""}`}>{toast.text}</div>}
    </ToastCtx.Provider>
  );
}

export interface IngredientHit {
  ingredient_id: number;
  inci_name: string;
  common_name: string | null;
  similarity: number;
}

/** Typeahead over canonical names + aliases (search_ingredients RPC, trigram-backed). */
export function IngredientPicker({ onPick, placeholder }: { onPick: (h: IngredientHit) => void; placeholder?: string }) {
  const [q, setQ] = useState("");
  const [hits, setHits] = useState<IngredientHit[]>([]);
  useEffect(() => {
    if (q.trim().length < 3) {
      setHits([]);
      return;
    }
    let live = true;
    const t = window.setTimeout(async () => {
      const { data } = await supabase.rpc("search_ingredients", { p_term: q, p_limit: 8 });
      if (live) setHits((data as IngredientHit[]) ?? []);
    }, 160);
    return () => {
      live = false;
      window.clearTimeout(t);
    };
  }, [q]);
  return (
    <div className="picker">
      <input className="input" value={q} onChange={(e) => setQ(e.target.value)} placeholder={placeholder ?? "Map to ingredient…"} aria-label="Search ingredients" />
      {hits.length > 0 && (
        <ul className="card">
          {hits.map((h) => (
            <li key={h.ingredient_id}>
              <button
                onClick={() => {
                  onPick(h);
                  setQ("");
                  setHits([]);
                }}
              >
                <span>{h.inci_name}{h.common_name ? <span style={{ color: "var(--muted)" }}> · {h.common_name}</span> : null}</span>
                <span style={{ color: "var(--faint)", fontSize: 12 }}>{Math.round(h.similarity * 100)}%</span>
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
