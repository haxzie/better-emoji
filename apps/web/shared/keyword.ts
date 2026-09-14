// Prefix search over CLDR names + keywords. Runs synchronously on the main
// thread and catches the cases embeddings can't: partial words ("cele"),
// exact names, and short tokens the encoder has no opinion about.

import type { EmojiEntry, Hit } from './types';

interface Token {
  text: string;
  emoji: number;
  /** 1 for a name word, lower for a keyword */
  weight: number;
}

const NAME_WEIGHT = 1;
const TAG_WEIGHT = 0.7;
const PREFIX_PENALTY = 0.8;

export function tokenize(s: string): string[] {
  return s
    .toLowerCase()
    .split(/[^a-z0-9'’]+/)
    .filter(Boolean);
}

export class KeywordIndex {
  private tokens: Token[] = [];
  private names: string[];

  constructor(emoji: EmojiEntry[]) {
    this.names = emoji.map((e) => e.n.toLowerCase());
    emoji.forEach((e, i) => {
      const seen = new Map<string, number>();
      for (const w of tokenize(e.n)) seen.set(w, NAME_WEIGHT);
      for (const tag of e.t) for (const w of tokenize(tag)) if (!seen.has(w)) seen.set(w, TAG_WEIGHT);
      for (const [text, weight] of seen) this.tokens.push({ text, emoji: i, weight });
    });
    this.tokens.sort((a, b) => (a.text < b.text ? -1 : a.text > b.text ? 1 : 0));
  }

  /** First index whose token is >= prefix (binary search). */
  private lowerBound(prefix: string): number {
    let lo = 0;
    let hi = this.tokens.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (this.tokens[mid].text < prefix) lo = mid + 1;
      else hi = mid;
    }
    return lo;
  }

  search(query: string, limit: number): Hit[] {
    const words = tokenize(query);
    if (!words.length) return [];

    // For each query word, best score per emoji. An emoji must match every word.
    let candidates: Map<number, number> | null = null;
    for (const w of words) {
      const matches = new Map<number, number>();
      for (let i = this.lowerBound(w); i < this.tokens.length; i++) {
        const tok = this.tokens[i];
        if (!tok.text.startsWith(w)) break;
        const s = tok.weight * (tok.text === w ? 1 : PREFIX_PENALTY);
        if (s > (matches.get(tok.emoji) ?? 0)) matches.set(tok.emoji, s);
      }
      if (candidates === null) {
        candidates = matches;
      } else {
        for (const [idx, prev] of candidates) {
          const s = matches.get(idx);
          if (s === undefined) candidates.delete(idx);
          else candidates.set(idx, prev + s);
        }
      }
      if (!candidates.size) return [];
    }

    const q = query.trim().toLowerCase();
    const hits: Hit[] = [];
    for (const [idx, sum] of candidates!) {
      let s = sum / words.length;
      const name = this.names[idx];
      if (name === q) s += 0.5; // exact name
      else if (name.startsWith(q)) s += 0.2; // "grinning" → "grinning face"
      else if (name.includes(q)) s += 0.1;
      // Shorter names are more specific matches for the same words.
      s -= Math.min(0.1, name.length / 1000);
      hits.push([idx, s]);
    }
    hits.sort((a, b) => b[1] - a[1]);
    return hits.slice(0, limit);
  }
}
