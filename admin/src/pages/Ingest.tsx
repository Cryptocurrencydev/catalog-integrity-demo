import { useState } from "react";
import { supabase } from "../supabase";
import { Chip, explainError, useToast } from "../ui";

const FIXTURES: { url: string; label: string; expect: string }[] = [
  { url: "https://velvane-skin.example/products/hydrating-facial-cleanser", label: "Velvane Skin · Hydrating Facial Cleanser", expect: "applied: alias mess (Aqua/Water/Eau, Parfum/Fragrance, Tocopherol (Vitamin E)) normalised, duplicate Water dropped" },
  { url: "https://northfern.example/p/niacinamide-10-serum", label: "Northfern · Niacinamide 10% Serum", expect: "applied: JSON-LD page, organic footnotes, 1,2-Hexanediol kept whole" },
  { url: "https://ondessa-hair.example/shop/repair-conditioner", label: "Ondessa Hair · Repair Conditioner", expect: "held: 3 unknown / fuzzy names go to the verification queue, catalog untouched" },
  { url: "https://saltglass.example/products/mineral-sunscreen-spf-30", label: "Saltglass · Mineral Sunscreen SPF 30", expect: "drafted: differs from a human-verified list, so a repair draft instead of an overwrite" },
  { url: "https://dermadeals.example/item/velvane-hydrating-cleanser-150ml", label: "DermaDeals · marketplace listing", expect: "drafted: suspect source cannot write the catalog directly" },
  { url: "https://petalwright.example/products/lip-conditioning-balm", label: "Petalwright · Lip Conditioning Balm", expect: "applied after retries: origin returns 503 twice; may-contain shades flagged optional" },
  { url: "https://petalwright.example/products/overnight-lip-mask", label: "Petalwright · Overnight Lip Mask", expect: "dead-lettered: origin always 503, 3 attempts with backoff; source allows 2 req/min" },
  { url: "https://halcyra.example/products/calm-barrier-cream", label: "Halcyra · Calm Barrier Cream", expect: "dead-lettered at parse: theme update removed the ingredient list" },
];

const TONE: Record<string, string> = { applied: "ok", unchanged: "", held_for_verification: "warn", drafted: "info", dead_lettered: "bad", rate_limited: "warn", rejected: "bad" };

export function IngestPage({ onChanged }: { onChanged: () => void }) {
  const toast = useToast();
  const [results, setResults] = useState<Record<string, Record<string, unknown>>>({});
  const [busy, setBusy] = useState<string | null>(null);

  async function ingest(url: string) {
    setBusy(url);
    try {
      const { data, error } = await supabase.functions.invoke("ingest-product-page", { body: { url } });
      if (error) throw error;
      const r = (data as { results: Record<string, unknown>[] }).results[0];
      setResults((prev) => ({ ...prev, [url]: r }));
      onChanged();
    } catch (e) {
      toast(explainError(e), true);
    } finally {
      setBusy(null);
    }
  }

  return (
    <>
      <div className="page-head">
        <div>
          <h1>Ingest fixtures</h1>
          <p>Runs the Deno edge function on local fixture pages that look like brand sites (no real scraping). Rate limit → fetch with backoff → parse → INCI split + normalise → alias matching → one transactional apply in Postgres.</p>
        </div>
      </div>
      <div className="list">
        {FIXTURES.map((f) => {
          const r = results[f.url];
          const status = r?.status as string | undefined;
          return (
            <article key={f.url} className="card item">
              <div className="item-top">
                <strong>{f.label}</strong>
                {status && <Chip tone={TONE[status] ?? ""}>{status.replace(/_/g, " ")}</Chip>}
              </div>
              <div className="meta"><span style={{ fontFamily: "var(--mono)" }}>{new URL(f.url).hostname}{new URL(f.url).pathname}</span></div>
              <div className="meta">Expected: {f.expect}</div>
              <div className="actions">
                <button className="btn primary sm" disabled={busy !== null} onClick={() => ingest(f.url)}>{busy === f.url ? "Ingesting…" : "Ingest"}</button>
              </div>
              {r && <pre className="json">{JSON.stringify(r, null, 2)}</pre>}
            </article>
          );
        })}
      </div>
    </>
  );
}
