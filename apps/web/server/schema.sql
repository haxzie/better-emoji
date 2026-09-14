-- Emoji vectors for the search API. Seeded by scripts/seed-api.mjs through
-- POST /api/v1/admin/reindex; the Worker loads the whole table into memory once
-- per isolate (1.9k rows × 384 floats ≈ 3 MB) and searches in-process.
CREATE TABLE IF NOT EXISTS emoji (
  id      INTEGER PRIMARY KEY,   -- position in emoji-meta.json, stable across rebuilds
  char    TEXT    NOT NULL,
  name    TEXT    NOT NULL,
  grp     INTEGER NOT NULL,      -- CLDR group; "group" is reserved in SQL
  tags    TEXT    NOT NULL,      -- JSON array
  skins   TEXT,                  -- JSON array of skin-tone variants, or NULL
  vec     BLOB    NOT NULL       -- 384 × float32, L2-normalised, little-endian
);
CREATE TABLE IF NOT EXISTS meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
