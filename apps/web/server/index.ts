// The Cloudflare Worker in front of emoji.haxzie.com.
//
// Static assets (the picker itself) are served by the platform without this
// code ever running — `run_worker_first` in wrangler.jsonc lists the only paths
// that reach it:
//
//   /download              302 → the current macOS build (DMG; zip for old releases)
//   /releases/latest.json  the manifest the release workflow writes to R2
//   /releases/<v>/<file>   the build itself, streamed from R2
//
// `.github/workflows/release-mirror.yml` is the other half: it copies each
// GitHub release's zip into the `better-emoji` bucket and rewrites latest.json.
// GitHub stays the source of truth (the in-app updater reads it directly);
// the bucket exists so the site's download button never depends on GitHub's
// API rate limit or its release CDN.

interface Env {
  RELEASES: R2Bucket;
  GITHUB_REPO: string;
}

/** Where objects live in the bucket, and where they appear on the site. */
const PREFIX = 'releases';

/** Shape of latest.json — the parts read here; the workflow writes more. */
interface Manifest {
  version?: unknown;
  /** The zip — what the in-app updater installs. */
  url?: unknown;
  /** The DMG — what people download. Absent on releases before 0.3.0. */
  dmg?: { url?: unknown };
}

/**
 * A path segment safe to look up in the bucket and echo into a URL. Versions
 * and artefact names only ever contain these; anything else is a probe.
 */
const SAFE_SEGMENT = /^[A-Za-z0-9._-]+$/;

export default {
  async fetch(request, env, ctx): Promise<Response> {
    const url = new URL(request.url);

    if (request.method !== 'GET' && request.method !== 'HEAD') {
      return new Response('Method Not Allowed', { status: 405, headers: { allow: 'GET, HEAD' } });
    }

    if (url.pathname === '/download') return download(request, env);

    if (url.pathname.startsWith(`/${PREFIX}/`)) return release(request, env, ctx);

    return new Response('Not Found', { status: 404 });
  },
} satisfies ExportedHandler<Env>;

/**
 * `/download` → the current build.
 *
 * A redirect rather than a link to a versioned file, so the URL on the hero,
 * in the README and in whatever someone pasted into a thread never changes.
 *
 * 302, not 301: a permanent redirect is cached by the browser for as long as it
 * likes, which would pin someone to whichever version they first clicked.
 *
 * Only the manifest's *path* is used, on this request's own origin. That makes
 * the redirect immune to scheme/host differences (wrangler dev rewrites the
 * host to the custom domain) and means a manifest can never send anyone off
 * this site — the worst a bad one can do is 404 under /releases/.
 */
async function download(request: Request, env: Env): Promise<Response> {
  const origin = new URL(request.url).origin;
  const fallback = `https://github.com/${env.GITHUB_REPO}/releases/latest`;

  let target = fallback;
  try {
    const object = await env.RELEASES.get(`${PREFIX}/latest.json`);
    const manifest = object ? ((await object.json()) as Manifest) : null;
    // People get the DMG (drag to Applications); the zip exists for the updater.
    const candidate = manifest?.dmg?.url ?? manifest?.url;
    if (typeof candidate === 'string') {
      const { pathname } = new URL(candidate, origin);
      if (pathname.startsWith(`/${PREFIX}/`)) target = origin + pathname;
    }
  } catch (error) {
    // The button still works — it just goes to GitHub, which is slower and
    // shows a page instead of starting the download.
    console.error('download: could not read latest.json', error);
  }

  return new Response(null, {
    status: 302,
    headers: {
      location: target,
      // Don't let an intermediate cache freeze the answer either.
      'cache-control': 'no-store',
    },
  });
}

/**
 * `/releases/<key>` → the object at `releases/<key>` in the bucket.
 *
 * Versioned objects are immutable, and the workflow stamps them as such, so a
 * copy is kept in the colo cache: the second download from a region never
 * touches R2. `latest.json` carries a 60 s `cache-control` of its own and goes
 * through the same path — it just expires quickly.
 *
 * Range requests go straight to R2 (resumed downloads, Safari probing the
 * size); they're rare and the cache would only ever see the first chunk.
 */
async function release(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  const url = new URL(request.url);
  const segments = url.pathname.split('/').slice(2); // drop "" and PREFIX
  if (!segments.length || !segments.every((s) => SAFE_SEGMENT.test(s))) {
    return new Response('Not Found', { status: 404 });
  }
  const key = `${PREFIX}/${segments.join('/')}`;

  const ranged = request.headers.has('range');
  const cache = caches.default;
  // Same URL as a GET so HEAD shares the entry; the request's own headers so
  // the cache can answer If-None-Match with a 304 itself.
  const cacheKey = new Request(url.toString(), { method: 'GET', headers: request.headers });

  if (!ranged) {
    const hit = await cache.match(cacheKey);
    if (hit) return request.method === 'HEAD' ? new Response(null, hit) : hit;
  }

  // Only the two conditions a browser sends on a GET. Passing every request
  // header would also apply If-Match / If-Unmodified-Since, whose failure
  // should be a 412 — and the body-less object R2 hands back doesn't say which
  // condition it was that failed.
  const onlyIf = new Headers();
  for (const name of ['if-none-match', 'if-modified-since']) {
    const value = request.headers.get(name);
    if (value) onlyIf.set(name, value);
  }

  let object: R2Object | R2ObjectBody | null;
  try {
    object = await env.RELEASES.get(key, ranged ? { range: request.headers, onlyIf } : { onlyIf });
  } catch {
    // R2 throws on a range it cannot satisfy rather than returning one it can.
    return new Response('Range Not Satisfiable', { status: 416 });
  }

  if (!object) return new Response('Not Found', { status: 404 });

  const headers = new Headers();
  object.writeHttpMetadata(headers);
  headers.set('etag', object.httpEtag);
  headers.set('accept-ranges', 'bytes');
  headers.set('access-control-allow-origin', '*');
  if (!headers.has('cache-control')) headers.set('cache-control', 'public, max-age=3600');

  // A condition matched: R2 returns the metadata without a body.
  if (!('body' in object)) return new Response(null, { status: 304, headers });

  if (ranged && object.range) {
    // R2Range is a union, but the local shim hands back every key with the
    // unused ones undefined — so check values, not key presence.
    const r = object.range as { offset?: number; length?: number; suffix?: number };
    let start: number;
    let length: number;
    if (typeof r.suffix === 'number') {
      length = Math.min(r.suffix, object.size);
      start = object.size - length;
    } else {
      start = r.offset ?? 0;
      length = r.length ?? object.size - start;
    }
    if (start >= object.size || length <= 0) {
      return new Response('Range Not Satisfiable', {
        status: 416,
        headers: { 'content-range': `bytes */${object.size}` },
      });
    }
    headers.set('content-range', `bytes ${start}-${start + length - 1}/${object.size}`);
    headers.set('content-length', String(length));
    return new Response(request.method === 'HEAD' ? null : object.body, { status: 206, headers });
  }

  headers.set('content-length', String(object.size));
  const response = new Response(object.body, { status: 200, headers });
  ctx.waitUntil(cache.put(cacheKey, response.clone()));
  return request.method === 'HEAD' ? new Response(null, response) : response;
}
