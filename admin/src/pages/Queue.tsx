import { useCallback, useEffect, useState } from "react";
import { must, supabase } from "../supabase";
import { Chip, explainError, fmt, IngredientPicker, timeAgo, useToast } from "../ui";

interface QueueItem {
  id: number;
  raw_name: string;
  normalized_name: string;
  reason: "unknown_ingredient" | "low_confidence" | "alias_conflict";
  similarity: number | null;
  created_at: string;
  source_url: string | null;
  product: { id: number; name: string; brand: { name: string } | null } | null;
  suggestion: { id: number; inci_name: string } | null;
}

const PAGE = 25;
const SELECT =
  "id, raw_name, normalized_name, reason, similarity, created_at, source_url, " +
  "product:products(id, name, brand:brands(name)), suggestion:ingredients!verification_queue_suggested_ingredient_id_fkey(id, inci_name)";

export function QueuePage({ onChanged }: { onChanged: () => void }) {
  const toast = useToast();
  const [items, setItems] = useState<QueueItem[] | null>(null);
  const [total, setTotal] = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<number | null>(null);
  const [more, setMore] = useState(false);
  const [form, setForm] = useState<{ id: number; kind: "new" | "reject"; text: string } | null>(null);

  const load = useCallback(async (after?: QueueItem) => {
    try {
      // Keyset pagination on (created_at, id), served by the partial index verification_queue_pending.
      let q = supabase.from("verification_queue").select(SELECT, { count: "exact" }).eq("status", "pending")
        .order("created_at").order("id").limit(PAGE);
      if (after) q = q.or(`created_at.gt.${after.created_at},and(created_at.eq.${after.created_at},id.gt.${after.id})`);
      const { data, error, count } = await q;
      if (error) throw error;
      const rows = (data ?? []) as unknown as QueueItem[];
      setItems((prev) => (after && prev ? [...prev, ...rows] : rows));
      setTotal(count ?? null);
      setMore(rows.length === PAGE);
      setError(null);
    } catch (e) {
      setError(explainError(e));
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  async function act(item: QueueItem, fn: () => PromiseLike<{ data: unknown; error: { message: string } | null }>) {
    setBusy(item.id);
    try {
      const r = (await must(fn())) as { items_resolved?: number; alias_added?: boolean; drafts_created?: number[]; status: string };
      const parts = [r.status === "rejected" ? "Rejected" : `Resolved ${r.items_resolved ?? 1} item${(r.items_resolved ?? 1) > 1 ? "s" : ""}`];
      if (r.alias_added) parts.push(`learned alias "${item.raw_name}"`);
      if (r.drafts_created?.length) parts.push(`repair draft #${r.drafts_created.join(", #")} created`);
      toast(parts.join(" · "));
      await load();
      onChanged();
    } catch (e) {
      toast(explainError(e), true);
    } finally {
      setBusy(null);
    }
  }

  const resolve = (item: QueueItem, ingredientId: number, addAlias = true) =>
    act(item, () => supabase.rpc("resolve_verification_item", { p_item_id: item.id, p_ingredient_id: ingredientId, p_add_alias: addAlias }));
  const submitForm = (item: QueueItem) => {
    if (!form || !form.text.trim()) return;
    const f = form;
    setForm(null);
    if (f.kind === "new") {
      act(item, () => supabase.rpc("resolve_verification_item", { p_item_id: item.id, p_new_inci_name: f.text, p_add_alias: true }));
    } else {
      act(item, () => supabase.rpc("reject_verification_item", { p_item_id: item.id, p_note: f.text }));
    }
  };

  return (
    <>
      <div className="page-head">
        <div>
          <h1>Verification queue</h1>
          <p>Label names the pipeline could not match with confidence. They are held here instead of entering the catalog. Resolving one learns an alias and resolves every open item with the same name; when a held page has no open items left, a repair draft is created.</p>
        </div>
        <Chip tone="accent">{fmt(total)} pending</Chip>
      </div>
      {error && <div className="error">{error}</div>}
      {!items && !error && <div className="list">{[0, 1, 2].map((i) => <div key={i} className="skeleton" />)}</div>}
      {items && items.length === 0 && <div className="card empty">Queue is empty. Ingest the Ondessa fixture page to fill it.</div>}
      <div className="list">
        {items?.map((it) => (
          <article key={it.id} className="card item" aria-busy={busy === it.id}>
            <div className="item-top">
              <span className="raw">{it.raw_name}</span>
              <Chip tone={it.reason === "unknown_ingredient" ? "bad" : "warn"}>{it.reason.replace("_", " ")}</Chip>
            </div>
            <div className="meta">
              {it.product && <span>{it.product.brand?.name} · {it.product.name}</span>}
              {it.source_url && <a href={it.source_url} onClick={(e) => e.preventDefault()} title={it.source_url}>{new URL(it.source_url).hostname}</a>}
              <span>{timeAgo(it.created_at)}</span>
              <span>#{it.id}</span>
            </div>
            <div className="actions">
              {it.suggestion && (
                <button className="btn primary sm" disabled={busy !== null} onClick={() => resolve(it, it.suggestion!.id)}>
                  Accept “{it.suggestion.inci_name}”{it.similarity ? ` · ${Math.round(it.similarity * 100)}%` : ""}
                </button>
              )}
              <IngredientPicker onPick={(h) => resolve(it, h.ingredient_id)} />
              <button className="btn sm" disabled={busy !== null} onClick={() => setForm({ id: it.id, kind: "new", text: it.raw_name })}>New ingredient</button>
              <button className="btn sm danger" disabled={busy !== null} onClick={() => setForm({ id: it.id, kind: "reject", text: "not an INCI name" })}>Not an ingredient</button>
            </div>
            {form?.id === it.id && (
              <form className="actions" onSubmit={(e) => { e.preventDefault(); submitForm(it); }}>
                <input className="input" style={{ flex: "1 1 240px" }} autoFocus value={form.text} aria-label={form.kind === "new" ? "Canonical INCI name" : "Rejection note"}
                  onChange={(e) => setForm({ ...form, text: e.target.value })} />
                <button className={`btn sm ${form.kind === "new" ? "primary" : "danger"}`} type="submit">
                  {form.kind === "new" ? "Create canonical ingredient" : "Reject"}
                </button>
                <button className="btn sm ghost" type="button" onClick={() => setForm(null)}>Cancel</button>
              </form>
            )}
          </article>
        ))}
      </div>
      {more && items && (
        <div style={{ textAlign: "center", marginTop: 14 }}>
          <button className="btn" onClick={() => load(items[items.length - 1])}>Load more</button>
        </div>
      )}
    </>
  );
}
