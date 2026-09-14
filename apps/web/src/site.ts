// The marketing chrome around the picker: repo link + star count in the nav,
// and the version/size of the current macOS build under the hero's download
// button. Both are decoration on links that work without them, so every
// failure here is silent.

export const REPO = 'haxzie/better-emoji';
export const REPO_URL = `https://github.com/${REPO}`;

const STARS_KEY = 'emoji-search:gh-stars';
const STARS_TTL = 60 * 60 * 1000; // GitHub allows 60 unauthenticated calls/hour per IP; one is plenty

/**
 * `1.2k` past a thousand, the plain number below it. Rounded down, so it never
 * reads higher than the repository's own page.
 */
export function formatStars(count: number): string {
  if (count < 1000) return String(count);
  return `${(Math.floor(count / 100) / 10).toFixed(1)}k`;
}

/** The repo's star count — from localStorage if it's under an hour old, else GitHub. */
export async function fetchStars(): Promise<number | null> {
  try {
    const cached = JSON.parse(localStorage.getItem(STARS_KEY) ?? 'null') as { n: number; t: number } | null;
    if (cached && Date.now() - cached.t < STARS_TTL) return cached.n;
  } catch {
    /* corrupt cache: refetch */
  }
  try {
    const r = await fetch(`https://api.github.com/repos/${REPO}`, {
      headers: { accept: 'application/vnd.github+json' },
    });
    if (!r.ok) return null;
    const { stargazers_count: n } = (await r.json()) as { stargazers_count?: unknown };
    if (typeof n !== 'number') return null;
    localStorage.setItem(STARS_KEY, JSON.stringify({ n, t: Date.now() }));
    return n;
  } catch {
    return null;
  }
}

/** What release-mirror.yml writes to R2 and the Worker serves at /releases/latest.json. */
export interface Release {
  version: string;
  size: number;
  url: string;
}

/**
 * The current build, or null when there isn't one yet (or in `vite dev`, where
 * the path answers with index.html). Cached for 60 s upstream, so this is cheap.
 */
export async function fetchLatestRelease(): Promise<Release | null> {
  try {
    const r = await fetch('/releases/latest.json', { headers: { accept: 'application/json' } });
    if (!r.ok || !r.headers.get('content-type')?.includes('json')) return null;
    const body = (await r.json()) as Partial<Release>;
    if (typeof body.version !== 'string' || typeof body.size !== 'number' || typeof body.url !== 'string') return null;
    return { version: body.version, size: body.size, url: body.url };
  } catch {
    return null;
  }
}

export function formatSize(bytes: number): string {
  return `${Math.round(bytes / 1_000_000)} MB`;
}
