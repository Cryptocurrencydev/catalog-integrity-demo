#!/usr/bin/env python3
"""EXPLAIN ANALYZE the hot queries before/after the workload indexes.

1. drop every index created in 20261103100700_scale_indexes.sql, ANALYZE
2. run each query in bench/queries.sql 7x (as its production role, inside a
   rolled-back transaction) and keep the median execution time + last plan
3. re-apply the index migration, ANALYZE, repeat
Writes bench/results.json, bench/RESULTS.md and bench/plans/{before,after}/*.txt.

Usage: python3 scripts/bench.py [db_url]
"""
import json, pathlib, re, statistics, subprocess, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DB = sys.argv[1] if len(sys.argv) > 1 else "postgresql://postgres:postgres@127.0.0.1:56322/postgres"
INDEX_MIGRATION = ROOT / "supabase/migrations/20261103100700_scale_indexes.sql"
RUNS = 7

ROLE_SETUP = {
    "anon": "set local role anon; select set_config('request.jwt.claims', '{\"role\":\"anon\"}', true);",
    "service_role": "set local role service_role; select set_config('request.jwt.claims', '{\"role\":\"service_role\"}', true);",
    "admin": "set local role authenticated; select set_config('request.jwt.claims', "
             "'{\"role\":\"authenticated\",\"sub\":\"00000000-0000-0000-0000-0000000000ad\",\"app_metadata\":{\"role\":\"admin\"}}', true);",
    "system": "",
}


def psql(sql: str, variables: dict | None = None) -> str:
    args = ["psql", DB, "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1"]
    for k, v in (variables or {}).items():
        args += ["-v", f"{k}={v}"]
    res = subprocess.run(args, input=sql, capture_output=True, text=True)
    if res.returncode != 0:
        raise RuntimeError(res.stderr)
    return res.stdout


def load_queries():
    text = (ROOT / "bench/queries.sql").read_text()
    out = []
    for block in re.split(r"^-- @", text, flags=re.M)[1:]:
        header, body = block.split("\n", 1)
        name, role = header.split()
        out.append((name, role, body.strip().rstrip(";")))
    return out


def params():
    row = psql("""
      select p.id, c.ingredients_hash, c.provider, c.model
      from public.products p
      join public.analysis_cache c on c.product_id = p.id
      where p.status = 'published' and p.ingredient_count >= 20 and c.analysis_kind = 'safety_narrative'
        and c.prompt_version = 'v3' and c.invalidated_at is null and not c.quarantined
        and exists (select 1 from public.audit_log a where a.product_id = p.id)
      order by p.id desc limit 1;""").strip().split("|")
    pid, h, provider, model = row
    reordered = psql(f"""
      select jsonb_agg(jsonb_build_object('ingredient_id', ingredient_id)
                       order by case position when 2 then 3 when 3 then 2 else position end)
      from public.product_ingredients where product_id = {pid};""").strip()
    return {"pid": pid, "hash": h, "provider": provider, "model": model, "term": "niacin", "product_term": "radiance retinol night", "reordered": reordered}


def run_query(role: str, body: str, variables: dict):
    times, plan = [], ""
    for _ in range(RUNS):
        out = psql(f"begin;\n{ROLE_SETUP[role]}\nexplain (analyze, buffers) {body};\nrollback;\n", variables)
        lines = [l for l in out.splitlines() if l and not l.startswith("{")]
        m = re.search(r"Execution Time: ([\d.]+) ms", out)
        times.append(float(m.group(1)))
        plan = "\n".join(lines)
    return statistics.median(times), plan


def index_names():
    return re.findall(r"create (?:unique )?index if not exists (\w+)", INDEX_MIGRATION.read_text())


def phase(label: str, queries, variables):
    results = {}
    plan_dir = ROOT / "bench/plans" / label
    plan_dir.mkdir(parents=True, exist_ok=True)
    for name, role, body in queries:
        ms, plan = run_query(role, body, variables)
        results[name] = ms
        (plan_dir / f"{name}.txt").write_text(plan + "\n")
        print(f"  {label:6} {name:20} {ms:10.3f} ms", flush=True)
    return results


def main():
    queries = load_queries()
    variables = params()
    stats = dict(zip(
        ["products", "product_ingredients", "ingredients", "aliases", "analysis_cache", "queue_pending", "queue_total", "audit_log"],
        psql("""select (select count(*) from public.products), (select count(*) from public.product_ingredients),
                       (select count(*) from public.ingredients), (select count(*) from public.ingredient_aliases),
                       (select count(*) from public.analysis_cache),
                       (select count(*) from public.verification_queue where status = 'pending'),
                       (select count(*) from public.verification_queue), (select count(*) from public.audit_log);"""
             ).strip().split("|")))
    print("dataset:", stats)

    psql("".join(f"drop index if exists public.{n};\n" for n in index_names()) + "analyze;")
    before = phase("before", queries, variables)
    psql(INDEX_MIGRATION.read_text() + "\nanalyze;")
    after = phase("after", queries, variables)

    data = {"dataset": {k: int(v) for k, v in stats.items()}, "params": {k: v for k, v in variables.items() if k != "reordered"},
            "runs_per_query": RUNS, "before_ms": before, "after_ms": after}
    (ROOT / "bench/results.json").write_text(json.dumps(data, indent=2) + "\n")

    rows = ["| Query | Role | Before (ms) | After (ms) | Speed-up |", "|---|---|---:|---:|---:|"]
    for name, role, _ in queries:
        b, a = before[name], after[name]
        rows.append(f"| {name} | {role} | {b:.2f} | {a:.2f} | {b / a:.0f}x |" if a else f"| {name} | {role} | {b:.2f} | {a:.2f} | |")
    ds = data["dataset"]
    md = (f"# Benchmark at {ds['products']:,} products\n\n"
          f"{ds['products']:,} products, {ds['product_ingredients']:,} list rows, {ds['ingredients']:,} ingredients, "
          f"{ds['aliases']:,} aliases, {ds['analysis_cache']:,} cache rows, {ds['queue_total']:,} queue rows "
          f"({ds['queue_pending']:,} pending), {ds['audit_log']:,} audit rows.\n\n"
          f"Median of {RUNS} warm runs of `EXPLAIN (ANALYZE, BUFFERS)`, each inside a rolled-back transaction, "
          f"as the role that issues the query in production (RLS on).\n\n" + "\n".join(rows) + "\n\n"
          "Plans: `bench/plans/before/*.txt` and `bench/plans/after/*.txt`.\n")
    (ROOT / "bench/RESULTS.md").write_text(md)
    print(md)


if __name__ == "__main__":
    main()
