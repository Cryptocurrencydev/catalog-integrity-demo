import { useCallback, useEffect, useMemo, useState } from "react";
import { diffLists, type ListRow } from "../diff";
import { must, supabase } from "../supabase";
import { Chip, explainError, fmt, Provenance, timeAgo, useToast } from "../ui";

interface Draft {
  id: number;
  product_id: number;
  proposed: { position: number; ingredient_id: number; inci_name: string; confidence: number | null }[];
  provenance: string;
  reason: string;
  base_hash: string | null;
  created_via: string;
  created_at: string;
  source: { domain: string; trust_level: string } | null;
  product: { id: number; name: string; ingredients_hash: string | null; brand: { name: string } | null } | null;
}

interface CurrentRow {
  position: number;
  ingredient_id: number;
  provenance_kind: string;
  ingredient: { inci_name: string; is_allergen: boolean };
}

const SELECT =
  "id, product_id, proposed, provenance, reason, base_hash, created_via, created_at, " +
  "source:sources(domain, trust_level), product:products(id, name, ingredients_hash, brand:brands(name))";

export function DraftsPage({ onChanged }: { onChanged: () => void }) {
  const toast = useToast();
  const [drafts, setDrafts] = useState<Draft[] | null>(null);
  const [selected, setSelected] = useState<number | null>(null);
  const [current, setCurrent] = useState<CurrentRow[] | null>(null);
  const [allergens, setAllergens] = useState<Set<number>>(new Set());
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      const rows = await must(
        supabase.from("repair_drafts").select(SELECT).eq("status", "pending").order("created_at").order("id").limit(100),
      );
      const list = rows as unknown as Draft[];
      setDrafts(list);
      setSelected((s) => (s && list.some((d) => d.id === s) ? s : list[0]?.id ?? null));
    } catch (e) {
      setError(explainError(e));
    }
  }, []);
  useEffect(() => {
    load();
  }, [load]);

  const draft = drafts?.find((d) => d.id === selected) ?? null;

  useEffect(() => {
    if (!draft) return;
    let live = true;
    setCurrent(null);
    (async () => {
      const rows = (await must(
        supabase.from("product_ingredients").select("position, ingredient_id, provenance_kind, ingredient:ingredients(inci_name, is_allergen)")
          .eq("product_id", draft.product_id).order("position"),
      )) as unknown as CurrentRow[];
      const ids = draft.proposed.map((p) => p.ingredient_id);
      const flagged = (await must(supabase.from("ingredients").select("id").in("id", ids).eq("is_allergen", true))) as { id: number }[];
      if (live) {
        setCurrent(rows);
        setAllergens(new Set(flagged.map((f) => f.id)));
      }
    })().catch((e) => setError(explainError(e)));
    return () => {
      live = false;
    };
  }, [draft]);

  const diff = useMemo(() => {
    if (!draft || !current) return null;
    const cur: ListRow[] = current.map((r) => ({
      ingredient_id: r.ingredient_id, inci_name: r.ingredient.inci_name, position: r.position,
      provenance: r.provenance_kind, is_allergen: r.ingredient.is_allergen,
    }));
    const prop: ListRow[] = draft.proposed.map((p) => ({ ingredient_id: p.ingredient_id, inci_name: p.inci_name, position: p.position, is_allergen: allergens.has(p.ingredient_id) }));
    return diffLists(cur, prop, allergens);
  }, [draft, current, allergens]);

  const stale = draft && draft.product && draft.base_hash !== draft.product.ingredients_hash;

  async function decide(kind: "approve" | "reject") {
    if (!draft) return;
    if (kind === "reject" && note.trim().length < 3) {
      toast("Add a short note explaining the rejection.", true);
      return;
    }
    setBusy(true);
    try {
      const r = (await must(
        kind === "approve"
          ? supabase.rpc("approve_repair_draft", { p_draft_id: draft.id, p_note: note || null })
          : supabase.rpc("reject_repair_draft", { p_draft_id: draft.id, p_note: note }),
      )) as Record<string, unknown>;
      if (r.status === "stale") toast(`Draft #${draft.id} is stale: the list changed after it was drafted. Nothing was applied.`, true);
      else if (kind === "approve") {
        toast(`Draft #${draft.id} applied via repair_product_ingredients · audit #${r.audit_id ?? "–"} · cache: ${r.cache_invalidated ?? 0} invalidated, ${r.cache_quarantined ?? 0} quarantined`);
      } else toast(`Draft #${draft.id} rejected`);
      setNote("");
      await load();
      onChanged();
    } catch (e) {
      toast(explainError(e), true);
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
      <div className="page-head">
        <div>
          <h1>Repair drafts</h1>
          <p>Proposed ingredient-list changes from the pipeline, AI reviewers and admins. Approving applies the draft through the same <code>repair_product_ingredients</code> RPC, guarded by the hash the draft was made against.</p>
        </div>
        <Chip tone="accent">{fmt(drafts?.length)} pending</Chip>
      </div>
      {error && <div className="error">{error}</div>}
      {drafts && drafts.length === 0 && <div className="card empty">No pending drafts. Ingest the Saltglass or DermaDeals fixture to create one.</div>}
      {drafts && drafts.length > 0 && (
        <div className="split">
          <nav className="card" aria-label="Pending drafts" style={{ maxHeight: "70vh", overflow: "auto" }}>
            {drafts.map((d) => (
              <button key={d.id} className="draft-btn" aria-pressed={d.id === selected} onClick={() => setSelected(d.id)}>
                <span className="t">{d.product?.name ?? `Product ${d.product_id}`}</span>
                <span className="meta" style={{ marginTop: 0 }}>
                  <span>{d.product?.brand?.name}</span><span>#{d.id}</span><span>{timeAgo(d.created_at)}</span>
                </span>
                <span className="stats"><Chip>{d.created_via}</Chip><Provenance kind={d.provenance} /></span>
              </button>
            ))}
          </nav>
          {draft && (
            <section className="card" aria-live="polite">
              <div className="diff-head">
                <h2>{draft.product?.brand?.name} · {draft.product?.name}</h2>
                <div className="meta" style={{ marginTop: 0 }}>
                  <span>Draft #{draft.id}</span>
                  <span>via {draft.created_via}</span>
                  {draft.source && <span>source {draft.source.domain} ({draft.source.trust_level})</span>}
                </div>
                <div className="notice">{draft.reason}</div>
                {diff && (
                  <div className="stats">
                    <Chip tone="ok">+{diff.added} added</Chip>
                    <Chip tone="bad">−{diff.removed} removed</Chip>
                    <Chip tone="warn">{diff.moved} moved</Chip>
                    {diff.material ? <Chip tone="bad">material: narratives will be quarantined</Chip> : <Chip>non-material: cache invalidated only</Chip>}
                    {stale && <Chip tone="bad">stale: list changed since drafted</Chip>}
                  </div>
                )}
              </div>
              {!diff && <div className="skeleton" style={{ margin: 14 }} />}
              {diff && (
                <ol className="diff" aria-label="Ingredient list diff">
                  {diff.rows.map((r) => (
                    <li key={`${r.kind}-${r.ingredient_id}`} className={r.kind}>
                      <span className="pos">
                        {r.kind === "removed" ? `${r.from}` : r.kind === "moved" ? `${r.from}→${r.to}` : r.to}
                      </span>
                      <span className="name">{r.inci_name}{r.is_allergen ? <span className="chip warn" style={{ marginLeft: 6 }}>allergen</span> : null}</span>
                      <span>{r.kind === "same" ? <Provenance kind={r.provenance} /> : <Chip tone={r.kind === "added" ? "ok" : r.kind === "removed" ? "bad" : "warn"}>{r.kind}</Chip>}</span>
                    </li>
                  ))}
                </ol>
              )}
              <div className="detail-actions">
                <textarea className="input" placeholder="Review note (required to reject)" value={note} onChange={(e) => setNote(e.target.value)} aria-label="Review note" />
                <div className="actions" style={{ marginTop: 0 }}>
                  <button className="btn primary" disabled={busy} onClick={() => decide("approve")}>Approve &amp; apply</button>
                  <button className="btn danger" disabled={busy} onClick={() => decide("reject")}>Reject</button>
                </div>
              </div>
            </section>
          )}
        </div>
      )}
    </>
  );
}
