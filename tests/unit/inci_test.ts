import { assertEquals } from "@std/assert";
import { dedupeByNormalized, normalizeInci, splitInciList } from "../../supabase/functions/_shared/inci.ts";

const vectors: { input: string; expected: string | null }[] = JSON.parse(
  await Deno.readTextFile(new URL("../normalize_vectors.json", import.meta.url)),
);

for (const v of vectors) {
  Deno.test(`normalizeInci(${JSON.stringify(v.input)})`, () => {
    assertEquals(normalizeInci(v.input), v.expected);
  });
}

Deno.test("split: commas, trailing period, digits-comma kept", () => {
  const t = splitInciList("Aqua, Glycerin, 1,2-Hexanediol, Caprylyl Glycol.");
  assertEquals(t.map((x) => x.raw), ["Aqua", "Glycerin", "1,2-Hexanediol", "Caprylyl Glycol"]);
});

Deno.test("split: label prefix and footnote lines dropped", () => {
  const t = splitInciList("Ingredients: Water (Aqua), Glycerin*, Aloe Barbadensis Leaf Juice*\n*Certified organic");
  assertEquals(t.map((x) => x.raw), ["Water (Aqua)", "Glycerin*", "Aloe Barbadensis Leaf Juice*"]);
});

Deno.test("split: commas inside parentheses do not split", () => {
  const t = splitInciList("Parfum (Fragrance, Natural), Linalool");
  assertEquals(t.map((x) => x.raw), ["Parfum (Fragrance, Natural)", "Linalool"]);
});

Deno.test("split: may contain (+/-) marks the tail optional", () => {
  const t = splitInciList("Cera Alba, Parfum, Limonene. May Contain (+/-): CI 77491, CI 77891.");
  assertEquals(t, [
    { raw: "Cera Alba", optional: false },
    { raw: "Parfum", optional: false },
    { raw: "Limonene", optional: false },
    { raw: "CI 77491", optional: true },
    { raw: "CI 77891", optional: true },
  ]);
});

Deno.test("split: bullets, semicolons and pipes", () => {
  const t = splitInciList("Aqua • Glycerin; Niacinamide | Zinc PCA");
  assertEquals(t.map((x) => x.raw), ["Aqua", "Glycerin", "Niacinamide", "Zinc PCA"]);
});

Deno.test("split: wrapped lines join with a space", () => {
  const t = splitInciList("Aqua, Butyrospermum Parkii\n(Shea) Butter, Glycerin");
  assertEquals(t.map((x) => x.raw), ["Aqua", "Butyrospermum Parkii (Shea) Butter", "Glycerin"]);
});

Deno.test("dedupe keeps first occurrence (label order)", () => {
  const out = dedupeByNormalized([
    { raw: "Glycerin", normalized: "glycerin" },
    { raw: "GLYCERIN.", normalized: "glycerin" },
    { raw: "Aqua", normalized: "aqua" },
  ]);
  assertEquals(out.map((x) => x.raw), ["Glycerin", "Aqua"]);
});
