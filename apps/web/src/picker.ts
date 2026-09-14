import type { EmojiEntry, EmojiMeta, Hit } from './types';
import { KeywordIndex } from '../shared/keyword';
import { merge as mergeHits } from '../shared/merge';
import { SemanticSearch, type SemanticState } from './semantic';
import { fetchLatestRelease, formatSize } from './site';

const RESULT_LIMIT = 48;
const SEMANTIC_CANDIDATES = 200; // ask for more than we show so keyword hits get a semantic score too
const DEBOUNCE_MS = 80;
const RECENT_KEY = 'emoji-search:recent';
const RECENT_LIMIT = 24;

// ---------------------------------------------------------------------------
// The markup lives in src/pages/index.astro (pre-rendered, so crawlers see it);
// this script only wires behaviour onto it.

const $ = <T extends Element>(sel: string) => document.querySelector<T>(sel)!;
const input = $<HTMLInputElement>('#q');
const clearBtn = $<HTMLButtonElement>('.clear');
const statusEl = $<HTMLDivElement>('.status');
const statusText = $<HTMLSpanElement>('.status-text');
const results = $<HTMLElement>('#results');
const detail = $<HTMLElement>('#detail');
const popover = $<HTMLDivElement>('#popover');
const toast = $<HTMLDivElement>('#toast');
const searchBar = $<HTMLElement>('.top');

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

const merge = (kw: Hit[], sem: Hit[] | null) => mergeHits(kw, sem, RESULT_LIMIT);

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
