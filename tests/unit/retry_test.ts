import { assertEquals, assertRejects } from "@std/assert";
import {
  backoffDelay,
  PermanentError,
  RetryableError,
  RetryExhaustedError,
  withRetry,
} from "../../supabase/functions/_shared/retry.ts";

const opts = (sleeps: number[]) => ({
  attempts: 4,
  baseDelayMs: 100,
  maxDelayMs: 1_000,
  sleep: (ms: number) => {
    sleeps.push(ms);
    return Promise.resolve();
  },
  random: () => 1, // upper bound of the jitter window -> deterministic
});

Deno.test("backoff doubles and caps", () => {
  const o = { baseDelayMs: 100, maxDelayMs: 1_000, random: () => 1 };
  assertEquals([1, 2, 3, 4, 5, 6].map((a) => backoffDelay(a, o)), [100, 200, 400, 800, 1000, 1000]);
  const low = { ...o, random: () => 0 };
  assertEquals(backoffDelay(3, low), 200); // equal jitter: never below half the step
});

Deno.test("retries transient failures then succeeds", async () => {
  const sleeps: number[] = [];
  let calls = 0;
  const r = await withRetry(() => {
    calls++;
    if (calls < 3) throw new RetryableError("http 503", 503);
    return Promise.resolve("ok");
  }, opts(sleeps));
  assertEquals(r, { value: "ok", attempts: 3 });
  assertEquals(sleeps, [100, 200]);
});

Deno.test("gives up after max attempts with the last status", async () => {
  const sleeps: number[] = [];
  const err = await assertRejects(
    () => withRetry(() => Promise.reject(new RetryableError("http 503", 503)), opts(sleeps)),
    RetryExhaustedError,
  );
  assertEquals([err.attempts, err.status], [4, 503]);
  assertEquals(sleeps, [100, 200, 400]);
});

Deno.test("permanent errors are not retried", async () => {
  const sleeps: number[] = [];
  const err = await assertRejects(
    () => withRetry(() => Promise.reject(new PermanentError("http 404", 404)), opts(sleeps)),
    RetryExhaustedError,
  );
  assertEquals([err.attempts, err.status, sleeps.length], [1, 404, 0]);
});
