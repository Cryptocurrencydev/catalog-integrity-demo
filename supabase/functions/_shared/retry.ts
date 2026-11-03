// Retries with exponential backoff + full jitter. Clock/sleep/random are
// injected so tests run instantly and deterministically.

export class RetryableError extends Error {
  constructor(message: string, readonly status?: number) {
    super(message);
    this.name = "RetryableError";
  }
}

export class PermanentError extends Error {
  constructor(message: string, readonly status?: number) {
    super(message);
    this.name = "PermanentError";
  }
}

export interface RetryOptions {
  attempts: number;
  baseDelayMs: number;
  maxDelayMs: number;
  sleep: (ms: number) => Promise<void>;
  random: () => number;
  onRetry?: (attempt: number, delayMs: number, err: unknown) => void;
}

export function backoffDelay(attempt: number, opts: Pick<RetryOptions, "baseDelayMs" | "maxDelayMs" | "random">) {
  const cap = Math.min(opts.maxDelayMs, opts.baseDelayMs * 2 ** (attempt - 1));
  // "equal jitter": never less than half the exponential step
  return Math.round(cap / 2 + opts.random() * (cap / 2));
}

export interface RetryResult<T> {
  value: T;
  attempts: number;
}

export class RetryExhaustedError extends Error {
  constructor(readonly lastError: unknown, readonly attempts: number) {
    super(lastError instanceof Error ? lastError.message : String(lastError));
    this.name = "RetryExhaustedError";
  }
  get status(): number | undefined {
    return (this.lastError as { status?: number })?.status;
  }
}

/** Retries anything except PermanentError up to `attempts`, then throws RetryExhaustedError. */
export async function withRetry<T>(fn: (attempt: number) => Promise<T>, opts: RetryOptions): Promise<RetryResult<T>> {
  for (let attempt = 1;; attempt++) {
    try {
      return { value: await fn(attempt), attempts: attempt };
    } catch (err) {
      if (err instanceof PermanentError || attempt >= opts.attempts) throw new RetryExhaustedError(err, attempt);
      const delay = backoffDelay(attempt, opts);
      opts.onRetry?.(attempt, delay, err);
      await opts.sleep(delay);
    }
  }
}
