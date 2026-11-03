import { describe, expect, it } from "vitest";
import { diffLists, type ListRow } from "./diff";

const L = (...names: string[]): ListRow[] => names.map((n, i) => ({ ingredient_id: n.charCodeAt(0), inci_name: n, position: i + 1 }));

describe("diffLists", () => {
  it("identical lists are all 'same' and not material", () => {
    const d = diffLists(L("Aqua", "Glycerin"), L("Aqua", "Glycerin"));
    expect(d.rows.map((r) => r.kind)).toEqual(["same", "same"]);
    expect(d.material).toBe(false);
  });
  it("detects a swap as two moves (material: top 5 changed)", () => {
    const d = diffLists(L("Aqua", "Glycerin", "Niacinamide"), L("Aqua", "Niacinamide", "Glycerin"));
    expect(d.moved).toBe(2);
    expect(d.rows.find((r) => r.inci_name === "Niacinamide")).toMatchObject({ from: 3, to: 2 });
    expect(d.material).toBe(true);
  });
  it("places removed rows after their predecessor", () => {
    const d = diffLists(L("Aqua", "Butylene", "Citric", "Phenoxy"), L("Aqua", "Citric", "Phenoxy"));
    expect(d.rows.map((r) => `${r.kind}:${r.inci_name}`)).toEqual([
      "same:Aqua", "removed:Butylene", "moved:Citric", "moved:Phenoxy",
    ]);
    expect(d.material).toBe(true);
  });
  it("appending a non-allergen below the top 5 is not material; an allergen is", () => {
    const base = L("A", "B", "C", "D", "E", "F");
    const plus = [...base, { ingredient_id: 999, inci_name: "Xanthan", position: 7 }];
    expect(diffLists(base, plus).material).toBe(false);
    expect(diffLists(base, plus, new Set([999])).material).toBe(true);
    expect(diffLists(base, plus).added).toBe(1);
  });
  it("first list ever is never material", () => {
    expect(diffLists([], L("Aqua")).material).toBe(false);
  });
});
