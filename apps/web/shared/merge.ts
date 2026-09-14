// Hybrid ranking: semantic similarity + a boost for keyword/prefix matches.
// One implementation for the browser picker, the Worker API and (ported) the
// Mac app, so "ship it" ranks the same everywhere.

import type { Hit } from './types';

export const KEYWORD_WEIGHT = 0.5; // final = semantic + KEYWORD_WEIGHT * keyword
export const SEMANTIC_MIN_KEEP = 12; // always keep at least this many semantic hits…
export const SEMANTIC_FLOOR = 0.35; // …beyond that, drop ones below this absolute score…
export const SEMANTIC_RELATIVE = 0.55; // …or far below the best semantic hit

export function merge(kw: Hit[], sem: Hit[] | null, limit: number): Hit[] {
  const scores = new Map<number, { k: number; s: number }>();
  for (const [i, k] of kw) scores.set(i, { k, s: 0 });
  if (sem?.length) {
    const cutoff = Math.max(SEMANTIC_FLOOR, sem[0][1] * SEMANTIC_RELATIVE);
    sem.forEach(([i, s], rank) => {
      const entry = scores.get(i);
      if (entry) entry.s = s;
      else if (rank < SEMANTIC_MIN_KEEP || s >= cutoff) scores.set(i, { k: 0, s });
    });
  }
  const out: Hit[] = [];
  for (const [i, { k, s }] of scores) out.push([i, s + KEYWORD_WEIGHT * k]);
  out.sort((a, b) => b[1] - a[1]);
  return out.slice(0, limit);
}
