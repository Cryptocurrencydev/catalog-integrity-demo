import { assertEquals } from "@std/assert";
import { FIXTURE_FILES } from "../../supabase/functions/ingest-product-page/fixtures.generated.ts";
import { fixtureFetch } from "../../supabase/functions/ingest-product-page/fixtures.ts";

const dir = new URL("../../supabase/functions/ingest-product-page/fixtures/", import.meta.url);

Deno.test("fixtures.generated.ts is up to date (run scripts/build-fixtures.ts)", async () => {
  const names: string[] = [];
  for await (const e of Deno.readDir(dir)) if (e.isFile) names.push(e.name);
  assertEquals(Object.keys(FIXTURE_FILES).sort(), names.sort());
  for (const n of names) assertEquals(FIXTURE_FILES[n], await Deno.readTextFile(new URL(n, dir)), n);
});

Deno.test("fixture fetch: flaky origin fails failTimes then serves; unknown url 404s", async () => {
  const u = "https://petalwright.example/products/lip-conditioning-balm";
  assertEquals((await fixtureFetch(u)).status, 503);
  assertEquals((await fixtureFetch(u)).status, 503);
  assertEquals((await fixtureFetch(u)).status, 200);
  assertEquals((await fixtureFetch("https://nope.example/")).status, 404);
});
