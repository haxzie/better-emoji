// Main-thread client for the embedding worker.

import type { EmojiMeta, Hit, WorkerRequest, WorkerResponse } from './types';

export type SemanticState =
  | { state: 'loading'; progress: number }
  | { state: 'ready' }
  | { state: 'error'; message: string };

export class SemanticSearch {
  private worker: Worker;
  private nextId = 0;
  private pending = new Map<number, (r: { hits: Hit[]; ms: number }) => void>();
  private _status: SemanticState = { state: 'loading', progress: 0 };
  onStatus: (s: SemanticState) => void = () => {};

  constructor(meta: EmojiMeta, indexUrl: string) {
    this.worker = new Worker(new URL('./worker.ts', import.meta.url), { type: 'module' });
    this.worker.onmessage = (e: MessageEvent<WorkerResponse>) => {
      const msg = e.data;
      if (msg.type === 'status') {
        this._status =
          msg.state === 'loading'
            ? { state: 'loading', progress: msg.progress ?? 0 }
            : msg.state === 'ready'
              ? { state: 'ready' }
              : { state: 'error', message: msg.message ?? 'unknown error' };
        this.onStatus(this._status);
      } else if (msg.type === 'result') {
        this.pending.get(msg.id)?.({ hits: msg.hits, ms: msg.ms });
        this.pending.delete(msg.id);
      }
    };
    this.worker.onerror = (e) => {
      this._status = { state: 'error', message: e.message };
      this.onStatus(this._status);
    };
    this.send({ type: 'init', indexUrl, model: meta.model, dim: meta.dim, count: meta.count });
  }

  get status() {
    return this._status;
  }

  get ready() {
    return this._status.state === 'ready';
  }

  search(query: string, limit: number): Promise<{ hits: Hit[]; ms: number }> {
    return new Promise((resolve) => {
      const id = this.nextId++;
      this.pending.set(id, resolve);
      this.send({ type: 'search', id, query, limit });
    });
  }

  private send(msg: WorkerRequest) {
    this.worker.postMessage(msg);
  }
}
