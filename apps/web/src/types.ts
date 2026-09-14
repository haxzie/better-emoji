export interface EmojiEntry {
  /** The emoji character itself */
  c: string;
  /** CLDR name, e.g. "grinning face" */
  n: string;
  /** CLDR keywords */
  t: string[];
  /** emojibase group id */
  g: number;
  /** Skin-tone variants, if any */
  s?: string[];
}

export interface EmojiMeta {
  model: string;
  dim: number;
  count: number;
  groups: Record<string, string>;
  emoji: EmojiEntry[];
}

/** [emoji index, score] */
export type Hit = [number, number];

export type WorkerRequest =
  | { type: 'init'; indexUrl: string; model: string; dim: number; count: number }
  | { type: 'search'; id: number; query: string; limit: number };

export type WorkerResponse =
  | { type: 'status'; state: 'loading' | 'ready' | 'error'; progress?: number; message?: string }
  | { type: 'result'; id: number; query: string; hits: Hit[]; ms: number };
