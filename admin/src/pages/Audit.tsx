import { useCallback, useEffect, useState } from "react";
import { must, supabase } from "../supabase";
import { Chip, explainError, timeAgo } from "../ui";

interface AuditRow {
  id: number;
  occurred_at: string;
  actor_kind: string;
  actor_id: string | null;
  action: string;
  entity: string;
  entity_id: string | null;
  product_id: number | null;
  diff: Record<string, unknown>;
  context: Record<string, unknown>;
}

const ACTIONS = [
  "", "repair_product_ingredients", "repair_draft_created", "repair_draft_approved", "repair_draft_rejected", "repair_draft_stale",
  "verification_resolved", "verification_rejected", "alias_learned", "ingredient_created", "source_trust_changed",
  "cache_quarantine_reviewed", "cache_hash_drift", "bulk_seed",
];
const PAGE = 40;

function summary(r: AuditRow): string {
  const d = r.diff as Record<string, unknown[] | unknown>;
  if (r.action === "repair_product_ingredients") {
    const n = (k: string) => (Array.isArray(d[k]) ? (d[k] as unknown[]).length : 0);
    const cache = d.cache as { invalidated?: number; quarantined?: number } | undefined;
    const bits = [`+${n("added")} −${n("removed")} ↕${n("moved")}`];
    if (n("provenance_upgraded")) bits.push(`${n("provenance_upgraded")} upgraded`);
    if (d.provenance) bits.push(String(d.provenance));
    if (cache && (cache.invalidated || cache.quarantined)) bits.push(`cache ${cache.invalidated ?? 0} inv / ${cache.quarantined ?? 0} quar`);
    return bits.join(" · ");
  }
  if (r.action === "alias_learned") return `"${d.alias}" → ${d.inci_name}`;
  if (r.action === "source_trust_changed") return `${d.domain}: ${d.from} → ${d.to}`;
  if (r.action === "verification_resolved") return `"${d.raw_name}" → ${d.inci_name} (${d.items_resolved} items)`;
  return "";
}

export function AuditPage() {
  const [rows, setRows] = useState<AuditRow[] | null>(null);
  const [action, setAction] = useState("");
  const [product, setProduct] = useState("");
  const [more, setMore] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async (before?: number) => {
    try {
      let q = supabase.from("audit_log").select("*").order("id", { ascending: false }).limit(PAGE);
      if (action) q = q.eq("action", action);
      if (/^\d+$/.test(product)) q = q.eq("product_id", Number(product));
      if (before) q = q.lt("id", before);
      const data = (await must(q)) as AuditRow[];
      setRows((prev) => (before && prev ? [...prev, ...data] : data));
      setMore(data.length === PAGE);
      setError(null);
    } catch (e) {
      setError(explainError(e));
    }
  }, [action, product]);
  useEffect(() => {
    const t = window.setTimeout(() => load(), 200);
    return () => window.clearTimeout(t);
  }, [load]);

  return (
    <>
      <div className="page-head">
        <div>
          <h1>Audit log</h1>
          <p>Append-only: a trigger rejects UPDATE, DELETE and TRUNCATE for every role. Each repair records the exact diff, the actor and the cache effect.</p>
        </div>
        <div className="filters">
          <select className="input" value={action} onChange={(e) => setAction(e.target.value)} aria-label="Filter by action">
            {ACTIONS.map((a) => <option key={a} value={a}>{a || "All actions"}</option>)}
          </select>
          <input className="input" style={{ width: 130 }} inputMode="numeric" placeholder="Product id" value={product} onChange={(e) => setProduct(e.target.value.trim())} aria-label="Filter by product id" />
        </div>
      </div>
      {error && <div className="error">{error}</div>}
      {!rows && !error && <div className="list">{[0, 1, 2].map((i) => <div key={i} className="skeleton" />)}</div>}
      {rows && rows.length === 0 && <div className="card empty">No audit rows match.</div>}
      <div className="card">
        {rows?.map((r) => (
          <details key={r.id} className="audit-row" style={{ borderBottom: "1px solid var(--border)" }}>
            <summary>
              <span className="act">{r.action}</span>
              <Chip tone={r.actor_kind === "admin" ? "info" : r.actor_kind === "service" ? "" : "accent"}>{r.actor_kind}</Chip>
              {r.product_id && <span className="meta" style={{ marginTop: 0 }}>product #{r.product_id}</span>}
              <span className="meta" style={{ marginTop: 0 }}>{summary(r)}</span>
              <span className="meta" style={{ marginTop: 0, marginLeft: "auto" }}>#{r.id} · {timeAgo(r.occurred_at)}</span>
            </summary>
            <pre className="json">{JSON.stringify({ diff: r.diff, context: r.context, actor_id: r.actor_id }, null, 2)}</pre>
          </details>
        ))}
      </div>
      {more && rows && (
        <div style={{ textAlign: "center", marginTop: 14 }}>
          <button className="btn" onClick={() => load(rows[rows.length - 1].id)}>Older</button>
        </div>
      )}
    </>
  );
}
