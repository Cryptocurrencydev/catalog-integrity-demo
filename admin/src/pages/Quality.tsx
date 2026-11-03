import { useCallback, useEffect, useState } from "react";
import { must, supabase } from "../supabase";
import { Chip, explainError, fmt, timeAgo, useToast } from "../ui";

interface Report {
  id: number;
  run_at: string;
  duration_ms: number;
  products_total: number;
  published_total: number;
  missing_ingredients: number;
  duplicate_groups: number;
  low_provenance_products: number;
  stale_cache_rows: number;
  quarantined_cache_rows: number;
  untrusted_source_products: number;
  pending_queue: number;
  oldest_pending_hours: number | null;
  stale_drafts: number;
  provenance_mix: Record<string, number>;
  samples: {
    missing_ingredients: { product_id: number; name: string }[];
    duplicates: { product_ids: number[]; name: string; count: number }[];
    low_provenance: { product_id: number; name: string }[];
  };
}

interface Run { id: number; job: string; started_at: string; finished_at: string | null; ok: boolean | null; details: Record<string, unknown> }
interface Quarantined { id: number; analysis_kind: string; provider: string; model: string; quarantined_at: string; product: { name: string } | null }

const MIX = [
  ["verified", "var(--ok)"],
  ["manual", "var(--info)"],
  ["scraped", "var(--faint)"],
  ["ai_suggested", "var(--warn)"],
] as const;

const SCHEDULE = [
  ["02:00", "url_trust", "re-probe source URLs (mocked), downgrade failing sources, audit changes"],
  ["02:15", "stale_cache", "invalidate expired AI output; alarm on hash drift"],
  ["02:30", "cleanup_orphans", "purge old cache rows, stale drafts, unused learned ingredients, rate windows"],
  ["02:45", "quality_report", "this report"],
];

export function QualityPage() {
  const toast = useToast();
  const [reports, setReports] = useState<Report[] | null>(null);
  const [runs, setRuns] = useState<Run[]>([]);
  const [quarantine, setQuarantine] = useState<Quarantined[]>([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      const [r, h, q] = await Promise.all([
        must(supabase.from("data_quality_reports").select("*").order("id", { ascending: false }).limit(8)),
        must(supabase.from("hygiene_runs").select("*").order("id", { ascending: false }).limit(8)),
        must(supabase.from("analysis_cache").select("id, analysis_kind, provider, model, quarantined_at, product:products(name)")
          .eq("quarantined", true).order("quarantined_at", { ascending: false }).limit(8)),
      ]);
      setReports(r as Report[]);
      setRuns(h as Run[]);
      setQuarantine(q as unknown as Quarantined[]);
    } catch (e) {
      setError(explainError(e));
    }
  }, []);
  useEffect(() => {
    load();
  }, [load]);

  async function runNow() {
    setBusy(true);
    try {
      const r = (await must(supabase.rpc("run_quality_report"))) as { duration_ms: number };
      toast(`Report generated in ${r.duration_ms} ms`);
      await load();
    } catch (e) {
      toast(explainError(e), true);
    } finally {
      setBusy(false);
    }
  }

  async function review(id: number) {
    try {
      await must(supabase.rpc("review_quarantined_cache", { p_cache_id: id, p_note: "reviewed in admin" }));
      toast(`Cache row #${id} reviewed (stays invalidated; will be regenerated)`);
      load();
    } catch (e) {
      toast(explainError(e), true);
    }
  }

  const r = reports?.[0];
  const mixTotal = r ? Object.values(r.provenance_mix).reduce((a, b) => a + b, 0) : 0;
  const kpis: [string, number | null | undefined, string?, string?][] = r ? [
    ["Published products", r.published_total, "", `${fmt(r.products_total)} total`],
    ["Published, no ingredients", r.missing_ingredients, r.missing_ingredients ? "bad" : ""],
    ["Duplicate groups", r.duplicate_groups, r.duplicate_groups ? "warn" : "", "same brand + name + list"],
    ["Low provenance mix", r.low_provenance_products, r.low_provenance_products ? "warn" : "", "≥30% AI rows, none reviewed"],
    ["Cache hash drift", r.stale_cache_rows, r.stale_cache_rows ? "bad" : "", "should always be 0"],
    ["Quarantined AI output", r.quarantined_cache_rows, r.quarantined_cache_rows ? "warn" : ""],
    ["From untrusted sources", r.untrusted_source_products, r.untrusted_source_products ? "warn" : "", "scraped rows, suspect source"],
    ["Pending queue", r.pending_queue, "", r.oldest_pending_hours != null ? `oldest ${Math.round(r.oldest_pending_hours)} h` : ""],
    ["Stale drafts", r.stale_drafts],
  ] : [];

  return (
    <>
      <div className="page-head">
        <div>
          <h1>Data quality</h1>
          <p>Nightly report written by pg_cron. Every number is computed in the database; this page only reads it.</p>
        </div>
        <button className="btn primary" disabled={busy} onClick={runNow}>{busy ? "Running…" : "Run report now"}</button>
      </div>
      {error && <div className="error">{error}</div>}
      {!reports && !error && <div className="kpis">{[0, 1, 2, 3].map((i) => <div key={i} className="skeleton" />)}</div>}
      {r && (
        <>
          <div className="meta" style={{ marginBottom: 10 }}>Report #{r.id} · {timeAgo(r.run_at)} · computed in {r.duration_ms} ms</div>
          <div className="kpis">
            {kpis.map(([label, v, tone, sub]) => (
              <div key={label} className={`card kpi ${tone ?? ""}`}>
                <div className="v">{fmt(v)}</div>
                <div className="l">{label}</div>
                {sub && <div className="l" style={{ color: "var(--faint)", fontSize: 12 }}>{sub}</div>}
              </div>
            ))}
          </div>

          <div className="section card" style={{ padding: 14 }}>
            <h2>Provenance mix · {fmt(mixTotal)} list rows</h2>
            <div className="mix" role="img" aria-label="Provenance mix">
              {MIX.map(([k, c]) => <span key={k} style={{ width: `${((r.provenance_mix[k] ?? 0) / mixTotal) * 100}%`, background: c }} />)}
            </div>
            <div className="legend">
              {MIX.map(([k, c]) => (
                <span key={k}><i style={{ background: c }} />{k.replace("_", " ")} {(((r.provenance_mix[k] ?? 0) / mixTotal) * 100).toFixed(1)}%</span>
              ))}
            </div>
          </div>

          <div className="section grid2">
            <div className="card">
              <h2 style={{ padding: "14px 14px 0" }}>Samples</h2>
              <table className="t">
                <tbody>
                  {r.samples.missing_ingredients.slice(0, 4).map((s) => (
                    <tr key={`m${s.product_id}`}><td><Chip tone="bad">no list</Chip></td><td>{s.name}</td><td className="num">#{s.product_id}</td></tr>
                  ))}
                  {r.samples.duplicates.slice(0, 4).map((s) => (
                    <tr key={`d${s.product_ids.join()}`}><td><Chip tone="warn">duplicate ×{s.count}</Chip></td><td style={{ textTransform: "capitalize" }}>{s.name}</td><td className="num">#{s.product_ids.join(", #")}</td></tr>
                  ))}
                  {r.samples.low_provenance.slice(0, 4).map((s) => (
                    <tr key={`l${s.product_id}`}><td><Chip tone="warn">AI-heavy</Chip></td><td>{s.name}</td><td className="num">#{s.product_id}</td></tr>
                  ))}
                </tbody>
              </table>
            </div>
            <div className="card">
              <h2 style={{ padding: "14px 14px 0" }}>Quarantined AI output</h2>
              {quarantine.length === 0 ? <div className="empty">Nothing quarantined.</div> : (
                <table className="t">
                  <tbody>
                    {quarantine.map((q) => (
                      <tr key={q.id}>
                        <td>{q.product?.name}<div className="meta" style={{ marginTop: 0 }}>{q.analysis_kind.replace("_", " ")} · {q.provider}/{q.model}</div></td>
                        <td className="num"><button className="btn sm" onClick={() => review(q.id)}>Mark reviewed</button></td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              )}
            </div>
          </div>
        </>
      )}

      <div className="section grid2">
        <div className="card scroll-x">
          <h2 style={{ padding: "14px 14px 0" }}>Nightly schedule (UTC, pg_cron)</h2>
          <table className="t">
            <tbody>{SCHEDULE.map(([t, j, d]) => <tr key={j}><td className="num" style={{ fontFamily: "var(--mono)" }}>{t}</td><td><code>{j}</code><div className="meta" style={{ marginTop: 0 }}>{d}</div></td></tr>)}</tbody>
          </table>
        </div>
        <div className="card scroll-x">
          <h2 style={{ padding: "14px 14px 0" }}>Recent hygiene runs</h2>
          <table className="t">
            <tbody>
              {runs.map((h) => (
                <tr key={h.id}>
                  <td><code>{h.job}</code><div className="meta" style={{ marginTop: 0 }}>{timeAgo(h.started_at)}</div></td>
                  <td>{h.ok ? <Chip tone="ok">ok</Chip> : <Chip tone="bad">failed</Chip>}</td>
                  <td className="num">{h.finished_at ? `${Math.max(1, Math.round(new Date(h.finished_at).getTime() - new Date(h.started_at).getTime()))} ms` : "…"}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
      {reports && reports.length > 1 && (
        <div className="section card scroll-x">
          <h2 style={{ padding: "14px 14px 0" }}>Report history</h2>
          <table className="t">
            <thead><tr><th>When</th><th className="num">Missing</th><th className="num">Dupes</th><th className="num">Low prov.</th><th className="num">Queue</th><th className="num">ms</th></tr></thead>
            <tbody>{reports.map((x) => <tr key={x.id}><td>{timeAgo(x.run_at)}</td><td className="num">{x.missing_ingredients}</td><td className="num">{x.duplicate_groups}</td><td className="num">{x.low_provenance_products}</td><td className="num">{x.pending_queue}</td><td className="num">{x.duration_ms}</td></tr>)}</tbody>
          </table>
        </div>
      )}
    </>
  );
}
