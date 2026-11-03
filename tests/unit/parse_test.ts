import { assertEquals, assertThrows } from "@std/assert";
import { decodeEntities, ParseError, parseProductPage } from "../../supabase/functions/_shared/parse.ts";
import { splitInciList } from "../../supabase/functions/_shared/inci.ts";

const dir = new URL("../../supabase/functions/ingest-product-page/fixtures/", import.meta.url);
const read = (f: string) => Deno.readTextFile(new URL(f, dir));

Deno.test("velvane: accordion <ul> list, og meta", async () => {
  const p = parseProductPage(await read("velvane-hydrating-cleanser.html"));
  assertEquals([p.brand, p.name, p.category, p.productType, p.strategy], [
    "Velvane Skin",
    "Hydrating Facial Cleanser",
    "skincare",
    "cleanser",
    "marked-element",
  ]);
  const t = splitInciList(p.ingredientsText);
  assertEquals(t.length, 23);
  assertEquals(t[0].raw, "Aqua/Water/Eau");
  assertEquals(t[12].raw, "Tocopherol (Vitamin E)");
  assertEquals(t.at(-1)!.raw, "Limonene");
});

Deno.test("northfern: JSON-LD name/brand, list in tab panel with organic footnote", async () => {
  const p = parseProductPage(await read("northfern-niacinamide-serum.html"));
  assertEquals([p.brand, p.name, p.productType], ["Northfern", "Niacinamide 10% Serum", "serum"]);
  const t = splitInciList(p.ingredientsText).map((x) => x.raw);
  assertEquals(t.length, 19);
  assertEquals(t[0], "Water (Aqua)");
  assertEquals(t.includes("1,2-Hexanediol"), true);
  assertEquals(t.some((x) => /certified/i.test(x)), false);
});

Deno.test("ondessa: <h3>Ingredients</h3> followed by paragraph", async () => {
  const p = parseProductPage(await read("ondessa-repair-conditioner.html"));
  assertEquals([p.brand, p.strategy, p.category], ["Ondessa Hair", "heading", "haircare"]);
  assertEquals(splitInciList(p.ingredientsText).length, 17);
});

Deno.test("saltglass: spec table <th>/<td>", async () => {
  const p = parseProductPage(await read("saltglass-mineral-sunscreen.html"));
  assertEquals([p.name, p.category, p.strategy], ["Mineral Sunscreen SPF 30", "suncare", "heading"]);
  assertEquals(splitInciList(p.ingredientsText).length, 12);
});

Deno.test("dermadeals: data-ingredients attribute, shouty label", async () => {
  const p = parseProductPage(await read("dermadeals-velvane-cleanser.html"));
  assertEquals(p.brand, "Velvane Skin");
  const t = splitInciList(p.ingredientsText).map((x) => x.raw);
  assertEquals(t[0], "AQUA");
  assertEquals(t.length, 9);
});

Deno.test("petalwright: <dt>/<dd> with may-contain shades", async () => {
  const p = parseProductPage(await read("petalwright-lip-balm.html"));
  const t = splitInciList(p.ingredientsText);
  assertEquals(t.filter((x) => x.optional).map((x) => x.raw), ["CI 77491", "CI 77891"]);
  assertEquals(t.length, 10);
});

Deno.test("halcyra: page without an ingredient list is a ParseError", async () => {
  const html = await read("halcyra-broken-page.html");
  assertThrows(() => parseProductPage(html), ParseError, "no ingredient list");
});

Deno.test("missing name / brand are ParseErrors", () => {
  assertThrows(() => parseProductPage("<html><body><p>hi</p></body></html>"), ParseError, "no product name");
  assertThrows(() => parseProductPage("<h1>Serum</h1>"), ParseError, "no brand");
});

Deno.test("entities decode", () => {
  assertEquals(decodeEntities("Cr&egrave;me &amp; Co &#8211; &#x2019;"), "Crème & Co – ’");
});
