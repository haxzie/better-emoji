import type { EmojiEntry, Hit } from '../shared/types';
export type { EmojiEntry, Hit };

export interface EmojiMeta {
  model: string;
  dim: number;
  count: number;
  groups: Record<string, string>;
  emoji: EmojiEntry[];
}

export type WorkerRequest =
  | { type: 'init'; indexUrl: string; model: string; dim: number; count: number }
  | { type: 'search'; id: number; query: string; limit: number };

export type WorkerResponse =
  | { type: 'status'; state: 'loading' | 'ready' | 'error'; progress?: number; message?: string }
  | { type: 'result'; id: number; query: string; hits: Hit[]; ms: number };
