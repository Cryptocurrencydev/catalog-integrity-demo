// Ordered ingredient-list diff for the repair-draft review screen.

export interface ListRow {
  ingredient_id: number;
  inci_name: string;
  position: number;
  provenance?: string;
  is_allergen?: boolean;
}

export type DiffKind = "same" | "added" | "removed" | "moved";

export interface DiffRow {
  kind: DiffKind;
  ingredient_id: number;
  inci_name: string;
  from?: number;
  to?: number;
  provenance?: string;
  is_allergen?: boolean;
}

export interface DiffSummary {
  rows: DiffRow[];
  added: number;
  removed: number;
  moved: number;
  /** Mirrors the DB's "material change" rule (quarantines narratives). */
  material: boolean;
}

/**
 * Proposed order drives the output; removed rows are placed right after the
 * row that preceded them in the current list, so reviewers read top-to-bottom.
 */
export function diffLists(current: ListRow[], proposed: ListRow[], allergenIds: Set<number> = new Set()): DiffSummary {
  const cur = [...current].sort((a, b) => a.position - b.position);
  const prop = [...proposed].sort((a, b) => a.position - b.position);
  const curById = new Map(cur.map((r) => [r.ingredient_id, r]));
  const propIds = new Set(prop.map((r) => r.ingredient_id));

  const rows: DiffRow[] = [];
  const removedAfter = new Map<number | null, ListRow[]>();
  let prevKept: number | null = null;
  for (const r of cur) {
    if (!propIds.has(r.ingredient_id)) {
      const list = removedAfter.get(prevKept) ?? [];
      list.push(r);
      removedAfter.set(prevKept, list);
    } else prevKept = r.ingredient_id;
  }
  const pushRemoved = (key: number | null) => {
    for (const r of removedAfter.get(key) ?? []) {
      rows.push({ kind: "removed", ingredient_id: r.ingredient_id, inci_name: r.inci_name, from: r.position, provenance: r.provenance, is_allergen: r.is_allergen });
    }
  };
  pushRemoved(null);
  for (const p of prop) {
    const c = curById.get(p.ingredient_id);
    const kind: DiffKind = !c ? "added" : c.position !== p.position ? "moved" : "same";
    rows.push({ kind, ingredient_id: p.ingredient_id, inci_name: p.inci_name, from: c?.position, to: p.position, provenance: c?.provenance, is_allergen: p.is_allergen ?? c?.is_allergen });
    if (c) pushRemoved(p.ingredient_id);
  }

  const added = rows.filter((r) => r.kind === "added");
  const removed = rows.filter((r) => r.kind === "removed").length;
  const moved = rows.filter((r) => r.kind === "moved").length;
  const top = (l: ListRow[]) => l.slice(0, 5).map((r) => r.ingredient_id).join(",");
  const material = cur.length > 0 && (removed > 0 || top(cur) !== top(prop) || added.some((r) => r.is_allergen || allergenIds.has(r.ingredient_id)));
  return { rows, added: added.length, removed, moved, material };
}
