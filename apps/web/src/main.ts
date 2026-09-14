import './style.css';
import type { EmojiEntry, EmojiMeta, Hit } from './types';
import { KeywordIndex } from './keyword';
import { SemanticSearch, type SemanticState } from './semantic';
import { REPO_URL, fetchLatestRelease, fetchStars, formatSize, formatStars } from './site';

const RESULT_LIMIT = 48;
const SEMANTIC_CANDIDATES = 200; // ask for more than we show so keyword hits get a semantic score too
const DEBOUNCE_MS = 80;
const KEYWORD_WEIGHT = 0.5; // final = semantic + KEYWORD_WEIGHT * keyword
const SEMANTIC_MIN_KEEP = 12; // always show at least this many semantic hits…
const SEMANTIC_FLOOR = 0.35; // …beyond that, drop ones below this absolute score…
const SEMANTIC_RELATIVE = 0.55; // …or far below the best semantic hit
const RECENT_KEY = 'emoji-search:recent';
const RECENT_LIMIT = 24;

// ---------------------------------------------------------------------------
// Shell

const APPLE_ICON = `<svg class="apple" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M16.37 12.7c-.02-2.36 1.93-3.5 2.02-3.55-1.1-1.61-2.81-1.83-3.42-1.86-1.46-.15-2.84.86-3.58.86-.74 0-1.88-.84-3.09-.82-1.59.02-3.05.93-3.87 2.35-1.65 2.86-.42 7.1 1.19 9.42.79 1.14 1.72 2.42 2.95 2.37 1.19-.05 1.63-.77 3.07-.77 1.43 0 1.83.77 3.09.75 1.27-.02 2.08-1.16 2.86-2.3.9-1.32 1.27-2.6 1.29-2.66-.03-.01-2.48-.95-2.51-3.79zM14.02 5.75c.65-.79 1.09-1.89.97-2.99-.94.04-2.08.63-2.75 1.42-.6.7-1.13 1.82-.99 2.9 1.05.08 2.12-.53 2.77-1.33z"/></svg>`;

const GITHUB_ICON = `<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M12 .5C5.65.5.5 5.65.5 12c0 5.08 3.29 9.39 7.86 10.91.58.1.79-.25.79-.56v-2.17c-3.2.7-3.87-1.36-3.87-1.36-.52-1.33-1.28-1.68-1.28-1.68-1.04-.71.08-.7.08-.7 1.15.08 1.76 1.19 1.76 1.19 1.03 1.76 2.69 1.25 3.35.96.1-.75.4-1.25.73-1.54-2.55-.29-5.24-1.28-5.24-5.68 0-1.26.45-2.28 1.19-3.09-.12-.29-.52-1.46.11-3.04 0 0 .97-.31 3.17 1.18a11 11 0 0 1 5.78 0c2.2-1.49 3.17-1.18 3.17-1.18.63 1.58.23 2.75.11 3.04.74.81 1.19 1.83 1.19 3.09 0 4.41-2.69 5.38-5.26 5.67.41.36.78 1.06.78 2.13v3.16c0 .31.21.67.8.56A11.51 11.51 0 0 0 23.5 12C23.5 5.65 18.35.5 12 .5z"/></svg>`;

const app = document.querySelector<HTMLDivElement>('#app')!;
app.innerHTML = `
  <nav class="nav" aria-label="Site">
    <a class="brand" href="/">
      <img src="/favicon.png" width="28" height="28" alt="" />
      <span>Better Emoji</span>
    </a>
    <div class="nav-actions">
      <a class="gh" href="${REPO_URL}" target="_blank" rel="noopener" aria-label="Better Emoji on GitHub">
        ${GITHUB_ICON}
        <span class="gh-label">GitHub</span>
        <span class="gh-stars" hidden aria-label="stars">
          <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M12 2.5l2.9 6.1 6.6.8-4.9 4.6 1.3 6.6L12 17.3l-5.9 3.3 1.3-6.6L2.5 9.4l6.6-.8z"/></svg>
          <span class="gh-count"></span>
        </span>
      </a>
      <a class="btn btn-sm" href="/download">${APPLE_ICON}<span>Download</span></a>
    </div>
  </nav>
  <section class="hero">
    <img class="hero-icon" src="/app-icon.png" width="96" height="96" alt="Better Emoji app icon" />
    <h1>Find the right emoji by describing it.</h1>
    <p class="hero-sub">
      Type “ship it”, “feeling great” or “we won” and get 🚀 😀 🏆. Semantic search that runs
      entirely on your Mac. No server, no tracking. A menu bar picker that opens with
      <kbd>⌃⌥Space</kbd>, anywhere you type.
    </p>
    <div class="hero-cta">
      <a class="btn btn-lg" href="/download">${APPLE_ICON}<span>Download for Mac</span></a>
      <p class="hero-meta">
        <span>macOS 14+</span><span>Apple Silicon</span><span>Free &amp; open source</span><span class="hero-version" hidden></span>
      </p>
    </div>
    <p class="hero-try">Or try the search right here ↓</p>
  </section>
  <header class="top">
    <label class="search" for="q">
      <svg class="search-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
        <circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>
      </svg>
      <input id="q" type="text" placeholder="Search emoji… try “ship it” or “feeling great”" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false" autofocus />
      <kbd class="hint" aria-hidden="true">↵ copies</kbd>
      <button class="clear" type="button" aria-label="Clear search" hidden>
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" aria-hidden="true"><path d="M6 6l12 12M18 6 6 18"/></svg>
      </button>
    </label>
    <div class="status" role="status" aria-live="polite">
      <span class="dot"></span>
      <span class="status-text">Loading…</span>
    </div>
  </header>
  <main class="results" id="results"></main>
  <aside class="detail" id="detail" hidden>
    <span class="detail-emoji"></span>
    <div class="detail-body">
      <div class="detail-name"></div>
      <div class="detail-tags"></div>
    </div>
  </aside>
  <div class="popover" id="popover" hidden role="menu"></div>
  <div class="toast" id="toast" role="status"></div>
`;

const $ = <T extends Element>(sel: string) => app.querySelector<T>(sel)!;
const input = $<HTMLInputElement>('#q');
const clearBtn = $<HTMLButtonElement>('.clear');
const statusEl = $<HTMLDivElement>('.status');
const statusText = $<HTMLSpanElement>('.status-text');
const results = $<HTMLElement>('#results');
const detail = $<HTMLElement>('#detail');
const popover = $<HTMLDivElement>('#popover');
const toast = $<HTMLDivElement>('#toast');
const searchBar = $<HTMLElement>('.top');

fetchStars().then((n) => {
  if (n === null) return;
  $<HTMLSpanElement>('.gh-count').textContent = formatStars(n);
  $<HTMLSpanElement>('.gh-stars').hidden = false;
});

fetchLatestRelease().then((release) => {
  if (!release) return;
  const el = $<HTMLSpanElement>('.hero-version');
  el.textContent = `v${release.version} · ${formatSize(release.size)}`;
  el.hidden = false;
});

// ---------------------------------------------------------------------------
// Data

const meta: EmojiMeta = await fetch('/emoji-meta.json').then((r) => r.json());
const emoji = meta.emoji;
const keyword = new KeywordIndex(emoji);
const semantic = new SemanticSearch(meta, '/emoji-index.bin');

const GROUP_LABELS: Record<string, string> = {
  'smileys-emotion': 'Smileys & Emotion',
  'people-body': 'People & Body',
  'animals-nature': 'Animals & Nature',
  'food-drink': 'Food & Drink',
  'travel-places': 'Travel & Places',
  activities: 'Activities',
  objects: 'Objects',
  symbols: 'Symbols',
  flags: 'Flags',
};

// ---------------------------------------------------------------------------
// Status pill

let lastSemanticMs: number | null = null;

function renderStatus(s: SemanticState = semantic.status) {
  statusEl.dataset.state = s.state;
  if (s.state === 'loading') {
    statusText.textContent = `Keyword search · loading semantic model ${Math.round(s.progress)}%`;
  } else if (s.state === 'ready') {
    statusText.textContent = lastSemanticMs === null
      ? 'Semantic search ready'
      : `Semantic + keyword · ${lastSemanticMs.toFixed(0)} ms`;
  } else {
    statusText.textContent = `Keyword only · semantic model failed (${s.message})`;
  }
}

semantic.onStatus = (s) => {
  renderStatus(s);
  // Upgrade whatever is on screen to semantic ranking as soon as we can.
  if (s.state === 'ready' && input.value.trim()) runSemantic(input.value.trim());
};
renderStatus();

// ---------------------------------------------------------------------------
// Rendering

function cell(idx: number): HTMLButtonElement {
  const e = emoji[idx];
  const b = document.createElement('button');
  b.type = 'button';
  b.className = 'cell';
  b.dataset.i = String(idx);
  b.textContent = e.c;
  b.title = e.n;
  b.setAttribute('aria-label', e.n);
  if (e.s) b.dataset.skins = '1';
  return b;
}

function grid(indices: number[]): HTMLDivElement {
  const g = document.createElement('div');
  g.className = 'grid';
  const frag = document.createDocumentFragment();
  for (const i of indices) frag.appendChild(cell(i));
  g.appendChild(frag);
  return g;
}

function section(title: string, indices: number[]): HTMLElement {
  const s = document.createElement('section');
  s.className = 'section';
  const h = document.createElement('h2');
  h.textContent = title;
  s.append(h, grid(indices));
  return s;
}

let browseView: DocumentFragment | null = null;

function buildBrowse(): DocumentFragment {
  const frag = document.createDocumentFragment();
  const recent = loadRecent();
  if (recent.length) frag.appendChild(section('Recent', recent));
  const byGroup = new Map<number, number[]>();
  emoji.forEach((e, i) => {
    if (!byGroup.has(e.g)) byGroup.set(e.g, []);
    byGroup.get(e.g)!.push(i);
  });
  for (const [g, indices] of [...byGroup].sort((a, b) => a[0] - b[0])) {
    const key = meta.groups[String(g)];
    frag.appendChild(section(GROUP_LABELS[key] ?? key, indices));
  }
  return frag;
}

function showBrowse() {
  results.dataset.mode = 'browse';
  results.replaceChildren();
  if (!browseView) browseView = buildBrowse();
  // Clone so we can reuse the built nodes next time.
  results.appendChild(browseView.cloneNode(true));
}

function showHits(hits: Hit[], query: string) {
  results.dataset.mode = 'search';
  if (!hits.length) {
    results.replaceChildren();
    const empty = document.createElement('p');
    empty.className = 'empty';
    empty.textContent = semantic.ready
      ? `Nothing for “${query}”`
      : `No keyword matches for “${query}” — semantic search is still loading`;
    results.appendChild(empty);
    return;
  }
  const g = grid(hits.map(([i]) => i));
  g.classList.add('grid-results');
  results.replaceChildren(g);
}

// ---------------------------------------------------------------------------
// Search orchestration

let currentQuery = '';
let lastKeywordHits: Hit[] = [];
let debounceTimer = 0;
let latestSemanticId = 0;

function merge(kw: Hit[], sem: Hit[] | null): Hit[] {
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
  return out.slice(0, RESULT_LIMIT);
}

function onQueryChange() {
  const q = input.value.trim();
  clearBtn.hidden = !q;
  hidePopover();
  if (q === currentQuery) return;
  currentQuery = q;
  syncUrl(q);
  scrollPastHero(q);
  latestSemanticId++;
  clearTimeout(debounceTimer);

  if (!q) {
    showBrowse();
    return;
  }

  // Keyword search is synchronous and cheap: render it on every keystroke.
  lastKeywordHits = keyword.search(q, RESULT_LIMIT);
  showHits(merge(lastKeywordHits, null), q);

  if (semantic.ready) {
    debounceTimer = window.setTimeout(() => runSemantic(q), DEBOUNCE_MS);
  }
}

async function runSemantic(q: string) {
  const id = ++latestSemanticId;
  const { hits, ms } = await semantic.search(q, SEMANTIC_CANDIDATES);
  if (id !== latestSemanticId || q !== currentQuery) return; // stale
  lastSemanticMs = ms;
  renderStatus();
  showHits(merge(lastKeywordHits, hits), q);
}

// The hero sits above the search bar. Once someone types, scroll the bar to the
// top so results aren't hidden below the fold — only when it's still below its
// sticky position, so a later keystroke never yanks the page around.
function scrollPastHero(q: string) {
  if (!q) return;
  const target = searchBar.offsetTop;
  if (window.scrollY >= target) return;
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  window.scrollTo({ top: target, behavior: reduce ? 'auto' : 'smooth' });
}

// Keep ?q= in the address bar so searches are shareable / reload-safe.
let urlTimer = 0;
function syncUrl(q: string) {
  clearTimeout(urlTimer);
  urlTimer = window.setTimeout(() => {
    const url = new URL(location.href);
    if (q) url.searchParams.set('q', q);
    else url.searchParams.delete('q');
    history.replaceState(null, '', url);
  }, 300);
}

input.addEventListener('input', onQueryChange);
clearBtn.addEventListener('click', () => {
  input.value = '';
  onQueryChange();
  input.focus();
});

// ---------------------------------------------------------------------------
// Picking, recents, toast

function loadRecent(): number[] {
  try {
    const chars: string[] = JSON.parse(localStorage.getItem(RECENT_KEY) ?? '[]');
    const byChar = new Map(emoji.map((e, i) => [e.c, i]));
    return chars.map((c) => byChar.get(c)).filter((i): i is number => i !== undefined);
  } catch {
    return [];
  }
}

function pushRecent(idx: number) {
  const chars = loadRecent().filter((i) => i !== idx).map((i) => emoji[i].c);
  chars.unshift(emoji[idx].c);
  localStorage.setItem(RECENT_KEY, JSON.stringify(chars.slice(0, RECENT_LIMIT)));
  browseView = null; // rebuild lazily with the new Recent row
}

let toastTimer = 0;
function showToast(text: string) {
  toast.textContent = text;
  toast.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = window.setTimeout(() => toast.classList.remove('show'), 1400);
}

async function pick(idx: number, char = emoji[idx].c) {
  try {
    await navigator.clipboard.writeText(char);
    showToast(`${char}  copied`);
  } catch {
    showToast(`${char}  couldn't access clipboard`);
  }
  pushRecent(idx);
}

results.addEventListener('click', (e) => {
  const b = (e.target as HTMLElement).closest<HTMLButtonElement>('.cell');
  if (b) pick(Number(b.dataset.i));
});

// ---------------------------------------------------------------------------
// Hover detail

function showDetail(entry: EmojiEntry) {
  detail.querySelector('.detail-emoji')!.textContent = entry.c;
  detail.querySelector('.detail-name')!.textContent = entry.n;
  detail.querySelector('.detail-tags')!.textContent = entry.t.join(' · ');
  detail.hidden = false;
}

results.addEventListener('mouseover', (e) => {
  const b = (e.target as HTMLElement).closest<HTMLButtonElement>('.cell');
  if (b) showDetail(emoji[Number(b.dataset.i)]);
});
results.addEventListener('mouseleave', () => (detail.hidden = true));
results.addEventListener('focusin', (e) => {
  const b = (e.target as HTMLElement).closest<HTMLButtonElement>('.cell');
  if (b) showDetail(emoji[Number(b.dataset.i)]);
});

// ---------------------------------------------------------------------------
// Skin tone popover (right-click / long-press a cell that has variants)

function hidePopover() {
  popover.hidden = true;
}

function showPopover(anchor: HTMLButtonElement) {
  const idx = Number(anchor.dataset.i);
  const entry = emoji[idx];
  if (!entry.s) return;
  popover.replaceChildren(
    ...[entry.c, ...entry.s].map((char) => {
      const b = document.createElement('button');
      b.type = 'button';
      b.className = 'cell';
      b.textContent = char;
      b.addEventListener('click', () => {
        pick(idx, char);
        hidePopover();
      });
      return b;
    }),
  );
  popover.hidden = false;
  const r = anchor.getBoundingClientRect();
  const w = popover.offsetWidth;
  const left = Math.min(Math.max(8, r.left + r.width / 2 - w / 2), window.innerWidth - w - 8);
  popover.style.left = `${left}px`;
  popover.style.top = `${r.bottom + 6 + window.scrollY}px`;
}

results.addEventListener('contextmenu', (e) => {
  const b = (e.target as HTMLElement).closest<HTMLButtonElement>('.cell');
  if (b?.dataset.skins) {
    e.preventDefault();
    showPopover(b);
  }
});

let pressTimer = 0;
results.addEventListener('pointerdown', (e) => {
  const b = (e.target as HTMLElement).closest<HTMLButtonElement>('.cell');
  if (!b?.dataset.skins || e.pointerType === 'mouse') return;
  pressTimer = window.setTimeout(() => showPopover(b), 450);
});
results.addEventListener('pointerup', () => clearTimeout(pressTimer));
results.addEventListener('pointercancel', () => clearTimeout(pressTimer));

document.addEventListener('click', (e) => {
  if (!popover.hidden && !popover.contains(e.target as Node)) hidePopover();
});
window.addEventListener('scroll', hidePopover, { passive: true });

// ---------------------------------------------------------------------------
// Keyboard

function visibleCells(): HTMLButtonElement[] {
  return [...results.querySelectorAll<HTMLButtonElement>('.cell')];
}

function columnsOf(g: HTMLElement): number {
  return getComputedStyle(g).gridTemplateColumns.split(' ').length;
}

input.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') {
    if (input.value) {
      input.value = '';
      onQueryChange();
    }
    hidePopover();
  } else if (e.key === 'Enter' && currentQuery) {
    const first = visibleCells()[0];
    if (first) pick(Number(first.dataset.i));
  } else if (e.key === 'ArrowDown') {
    e.preventDefault();
    visibleCells()[0]?.focus();
  }
});

results.addEventListener('keydown', (e) => {
  const cur = (e.target as HTMLElement).closest<HTMLButtonElement>('.cell');
  if (!cur) return;
  const cells = visibleCells();
  const i = cells.indexOf(cur);
  const cols = columnsOf(cur.parentElement!);
  let next = -1;
  switch (e.key) {
    case 'ArrowRight': next = i + 1; break;
    case 'ArrowLeft': next = i - 1; break;
    case 'ArrowDown': next = i + cols; break;
    case 'ArrowUp': next = i - cols; break;
    case 'Escape': hidePopover(); input.focus(); return;
    default:
      // Printable key: jump back to the search box and let it receive the character.
      if (e.key.length === 1 && !e.metaKey && !e.ctrlKey && !e.altKey) input.focus();
      return;
  }
  e.preventDefault();
  if (next < 0) input.focus();
  else cells[Math.min(next, cells.length - 1)]?.focus();
});

document.addEventListener('keydown', (e) => {
  // "/" or ⌘K focuses search from anywhere.
  if ((e.key === '/' && document.activeElement !== input) || ((e.metaKey || e.ctrlKey) && e.key === 'k')) {
    e.preventDefault();
    input.focus();
    input.select();
  }
});

// ---------------------------------------------------------------------------

const initial = new URLSearchParams(location.search).get('q') ?? '';
if (initial) {
  input.value = initial;
  onQueryChange();
} else {
  showBrowse();
}
input.focus();

if (import.meta.env.DEV) {
  // Handy for poking at ranking from the console during development.
  Object.assign(window, { __emoji: { meta, keyword, semantic } });
}
