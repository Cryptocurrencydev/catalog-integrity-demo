// Fixture "web": the demo never scrapes real sites. URLs map to local HTML
// files (embedded at build time, see scripts/build-fixtures.ts); failTimes
// simulates a flaky origin (first N requests fail).
import type { FetchResponse } from "../_shared/pipeline.ts";
import { FIXTURE_FILES } from "./fixtures.generated.ts";

interface FixtureEntry {
  file: string;
  failTimes?: number;
  failStatus?: number;
}

const index: Record<string, FixtureEntry> = JSON.parse(FIXTURE_FILES["index.json"]);
const hits = new Map<string, number>();

export function fixtureFetch(url: string): Promise<FetchResponse> {
  const entry = index[url];
  if (!entry) return Promise.resolve({ status: 404, body: "not found" });
  const n = (hits.get(url) ?? 0) + 1;
  hits.set(url, n);
  if (entry.failTimes && n <= entry.failTimes) {
    return Promise.resolve({ status: entry.failStatus ?? 503, body: "upstream unavailable" });
  }
  return Promise.resolve({ status: 200, body: FIXTURE_FILES[entry.file] });
}

export const fixtureUrls = () => Object.keys(index);
