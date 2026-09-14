// The search API.
//
//   GET  /api/v1/search?q=ship+it&limit=10   ranked emoji for a phrase
//   GET  /api/v1/status                        model, index size, last reindex
//   POST /api/v1/admin/reindex                 (Bearer ADMIN_TOKEN) upsert emoji + vectors
//
// The query is embedded by Workers AI; the emoji vectors live in D1 and are
// loaded into the isolate once, so a search is one AI call plus ~1.9k dot
// products in memory. Ranking is the same keyword+semantic merge the picker
// uses (shared/merge.ts), so the API agrees with the app.

import { KeywordIndex } from '../shared/keyword';
import { merge } from '../shared/merge';
import type { EmojiEntry, Hit } from '../shared/types';

export interface ApiEnv {
  AI: Ai;
  DB: D1Database;
  SEARCH_LIMITER: RateLimit;
  ADMIN_TOKEN?: string;
}

export const MODEL = '@cf/baai/bge-small-en-v1.5';
const DIM = 384;
const DEFAULT_LIMIT = 10;
const MAX_LIMIT = 50;
const MAX_QUERY_CHARS = 200;
const SEMANTIC_CANDIDATES = 200;
const CACHE_TTL = 3600; // identical queries are served from the edge for an hour
const AI_BATCH = 100; // texts per Workers AI call

// ── Routing ──────────────────────────────────────────────────────────────────

export async function api(request: Request, env: ApiEnv, ctx: ExecutionContext): Promise<Response> {
  const url = new URL(request.url);
  if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });

  switch (url.pathname) {
    case '/api/v1/search':
      if (request.method !== 'GET' && request.method !== 'HEAD') return error(405, 'method_not_allowed', 'Use GET');
      return search(request, env, ctx);
    case '/api/v1/status':
      return status(env);
    case '/api/v1/admin/reindex':
      if (request.method !== 'POST') return error(405, 'method_not_allowed', 'Use POST');
      return reindex(request, env);
    default:
      return error(404, 'not_found', 'No such endpoint. See https://emoji.haxzie.com/api');
  }
}

// ── Search ───────────────────────────────────────────────────────────────────

async function search(request: Request, env: ApiEnv, ctx: ExecutionContext): Promise<Response> {
  const url = new URL(request.url);
  const q = (url.searchParams.get('q') ?? '').trim().slice(0, MAX_QUERY_CHARS);
  if (!q) return error(400, 'missing_query', 'Pass the phrase to search for as ?q=');
  const limit = Math.min(MAX_LIMIT, Math.max(1, Number(url.searchParams.get('limit')) || DEFAULT_LIMIT));

  // Per-IP limit first: cheap, and it applies to cached answers too.
  const ip = request.headers.get('cf-connecting-ip') ?? 'unknown';
  const { success } = await env.SEARCH_LIMITER.limit({ key: ip });
  if (!success) {
    return error(429, 'rate_limited', 'Too many requests — 60 per minute per IP', { 'Retry-After': '60' });
  }

  // Same phrase → same answer for an hour, without touching the model.
  const cacheKey = new Request(`${url.origin}/api/v1/search?q=${encodeURIComponent(q.toLowerCase())}&limit=${limit}`);
  const cached = await caches.default.match(cacheKey);
  if (cached) return cached;

  const t0 = Date.now();
  const [index, query] = await Promise.all([loadIndex(env), embed(env, [q])]);
  if (!index) return error(503, 'index_empty', 'The index has not been built yet');

  const semantic = topK(index, query[0], SEMANTIC_CANDIDATES);
  const keyword = index.keyword.search(q, MAX_LIMIT);
  const hits = merge(keyword, semantic, limit);

  const body = {
    query: q,
    model: MODEL,
    took_ms: Date.now() - t0,
    results: hits.map(([i, score]) => {
      const e = index.entries[i];
      return { emoji: e.c, name: e.n, group: index.groups[e.g] ?? String(e.g), score: round(score), ...(e.s ? { skins: e.s } : {}) };
    }),
  };
  const res = json(body, 200, { 'Cache-Control': `public, max-age=${CACHE_TTL}` });
  ctx.waitUntil(caches.default.put(cacheKey, res.clone()));
  return res;
}

function topK(index: Index, query: Float32Array, k: number): Hit[] {
  const { vecs, count } = index;
  const scores: Hit[] = new Array(count);
  for (let i = 0; i < count; i++) {
    const off = i * DIM;
    let s = 0;
    for (let d = 0; d < DIM; d++) s += query[d] * vecs[off + d];
    scores[i] = [i, s];
  }
  scores.sort((a, b) => b[1] - a[1]);
  return scores.slice(0, k);
}

// ── Index in memory ──────────────────────────────────────────────────────────

interface Index {
  count: number;
  entries: EmojiEntry[];
  vecs: Float32Array;
  keyword: KeywordIndex;
  groups: Record<number, string>;
  updatedAt: string | null;
}

// Module-level: survives across requests in the same isolate. Reset by reindex().
let indexPromise: Promise<Index | null> | null = null;

function loadIndex(env: ApiEnv): Promise<Index | null> {
  return (indexPromise ??= (async () => {
    const { results } = await env.DB
      .prepare('SELECT id, char, name, grp, tags, skins, vec FROM emoji ORDER BY id')
      .all<{ id: number; char: string; name: string; grp: number; tags: string; skins: string | null; vec: ArrayBuffer | number[] }>();
    if (!results.length) {
      indexPromise = null; // try again next time — the seed may be in flight
      return null;
    }
    const count = results.length;
    const vecs = new Float32Array(count * DIM);
    const entries: EmojiEntry[] = new Array(count);
    results.forEach((r, i) => {
      const buf = r.vec instanceof ArrayBuffer ? r.vec : Uint8Array.from(r.vec).buffer;
      vecs.set(new Float32Array(buf, 0, DIM), i * DIM);
      entries[i] = { c: r.char, n: r.name, t: JSON.parse(r.tags), g: r.grp, ...(r.skins ? { s: JSON.parse(r.skins) } : {}) };
    });
    const meta = await env.DB.prepare("SELECT key, value FROM meta").all<{ key: string; value: string }>();
    const kv = Object.fromEntries(meta.results.map((m) => [m.key, m.value]));
    return {
      count,
      entries,
      vecs,
      keyword: new KeywordIndex(entries),
      groups: kv.groups ? JSON.parse(kv.groups) : {},
      updatedAt: kv.updatedAt ?? null,
    };
  })());
}

// ── Embeddings ───────────────────────────────────────────────────────────────

async function embed(env: ApiEnv, texts: string[]): Promise<Float32Array[]> {
  const out: Float32Array[] = [];
  for (let i = 0; i < texts.length; i += AI_BATCH) {
    const res = (await env.AI.run(MODEL, { text: texts.slice(i, i + AI_BATCH) })) as { data: number[][] };
    for (const v of res.data) out.push(normalize(Float32Array.from(v)));
  }
  return out;
}

function normalize(v: Float32Array): Float32Array {
  let n = 0;
  for (let d = 0; d < v.length; d++) n += v[d] * v[d];
  n = Math.sqrt(n) || 1;
  for (let d = 0; d < v.length; d++) v[d] /= n;
  return v;
}

// ── Status ───────────────────────────────────────────────────────────────────

async function status(env: ApiEnv): Promise<Response> {
  const index = await loadIndex(env);
  return json({ model: MODEL, dimensions: DIM, emoji: index?.count ?? 0, updated_at: index?.updatedAt ?? null, rate_limit: '60 requests / minute / IP' });
}

// ── Reindex (admin) ──────────────────────────────────────────────────────────
//
// Body: { reset?: boolean, groups?: Record<number,string>, items: [{ id, char, name, group, tags, skins?, blobs }] }
// Each item's vector is the normalised mean of its blobs' embeddings — the
// same recipe as packages/emoji-index/scripts/build-index.mjs. Called in
// chunks by scripts/seed-api.mjs to stay under the per-request subrequest cap.

interface ReindexItem { id: number; char: string; name: string; group: number; tags: string[]; skins?: string[]; blobs: string[] }

async function reindex(request: Request, env: ApiEnv): Promise<Response> {
  const auth = request.headers.get('authorization') ?? '';
  if (!env.ADMIN_TOKEN || auth !== `Bearer ${env.ADMIN_TOKEN}`) return error(401, 'unauthorized', 'Bad or missing admin token');

  const body = (await request.json()) as { reset?: boolean; groups?: Record<number, string>; items?: ReindexItem[] };
  const items = body.items ?? [];
  if (items.length > 100) return error(400, 'too_many_items', 'Send at most 100 items per call');

  if (body.reset) await env.DB.prepare('DELETE FROM emoji').run();

  // Flatten blobs, embed in batches, regroup by owner.
  const texts: string[] = [];
  const owner: number[] = [];
  items.forEach((it, i) => { for (const b of it.blobs) { texts.push(b); owner.push(i); } });
  const vectors = await embed(env, texts);

  const sums = items.map(() => new Float32Array(DIM));
  vectors.forEach((v, k) => { const s = sums[owner[k]]; for (let d = 0; d < DIM; d++) s[d] += v[d]; });

  const stmt = env.DB.prepare('INSERT OR REPLACE INTO emoji (id, char, name, grp, tags, skins, vec) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)');
  const batch = items.map((it, i) =>
    stmt.bind(it.id, it.char, it.name, it.group, JSON.stringify(it.tags), it.skins ? JSON.stringify(it.skins) : null, normalize(sums[i]).buffer),
  );
  const metaStmt = env.DB.prepare('INSERT OR REPLACE INTO meta (key, value) VALUES (?1, ?2)');
  batch.push(metaStmt.bind('updatedAt', new Date().toISOString()), metaStmt.bind('model', MODEL));
  if (body.groups) batch.push(metaStmt.bind('groups', JSON.stringify(body.groups)));
  if (batch.length) await env.DB.batch(batch);

  indexPromise = null; // next search reloads
  return json({ upserted: items.length, embedded: texts.length });
}

// ── Helpers ──────────────────────────────────────────────────────────────────

const CORS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
};

function json(body: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json; charset=utf-8', ...CORS, ...extra },
  });
}

function error(status: number, code: string, message: string, extra: Record<string, string> = {}): Response {
  return json({ error: code, message }, status, { 'Cache-Control': 'no-store', ...extra });
}

const round = (n: number) => Math.round(n * 1000) / 1000;
