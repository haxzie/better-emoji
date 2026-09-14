// Generate natural-language phrasings for every emoji with Claude and merge
// them into scripts/phrasings.json. Needs ANTHROPIC_API_KEY (or `ant auth login`).
//
//   pnpm gen-phrasings            # only emoji that have no phrasings yet
//   pnpm gen-phrasings --all   # regenerate everything
//
// Then rebuild the index: pnpm build

import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import Anthropic from '@anthropic-ai/sdk';
import compact from 'emojibase-data/en/compact.json' with { type: 'json' };

const here = path.dirname(fileURLToPath(import.meta.url));
const phrasingsPath = path.join(here, 'phrasings.json');
const BATCH = 40;
const CONCURRENCY = 4;
const regenerateAll = process.argv.includes('--all');

const phrasings = JSON.parse(readFileSync(phrasingsPath, 'utf8'));
const emoji = compact.filter((e) => e.group !== undefined && e.group !== 2);
const todo = emoji.filter((e) => regenerateAll || !phrasings[e.hexcode]?.length);
console.log(`${todo.length} emoji need phrasings`);
if (!todo.length) process.exit(0);

const client = new Anthropic();

const SYSTEM = `You write search phrasings for an emoji picker. For each emoji you are given its
character, CLDR name and keywords. Return 4-6 short phrasings per emoji: the things a person would
actually type into a search box when they want that emoji. Mix literal names, slang, feelings,
situations and common abbreviations ("lol", "brb", "wfh"). Lowercase. No hashtags, no emoji
characters, no duplicates of the given name. Keep each phrasing under 5 words.`;

const schema = {
  type: 'object',
  properties: {
    results: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          hexcode: { type: 'string' },
          phrasings: { type: 'array', items: { type: 'string' } },
        },
        required: ['hexcode', 'phrasings'],
        additionalProperties: false,
      },
    },
  },
  required: ['results'],
  additionalProperties: false,
};

async function generate(batch) {
  const list = batch
    .map((e) => `${e.hexcode}\t${e.unicode}\t${e.label}\t${(e.tags ?? []).join(', ')}`)
    .join('\n');
  const response = await client.messages.create({
    model: 'claude-opus-5',
    max_tokens: 16000,
    system: SYSTEM,
    messages: [{ role: 'user', content: `hexcode\temoji\tname\tkeywords\n${list}` }],
    output_config: { format: { type: 'json_schema', schema } },
  });
  const text = response.content.find((b) => b.type === 'text')?.text ?? '{"results":[]}';
  return JSON.parse(text).results;
}

const batches = [];
for (let i = 0; i < todo.length; i += BATCH) batches.push(todo.slice(i, i + BATCH));

let done = 0;
async function worker() {
  while (batches.length) {
    const batch = batches.shift();
    try {
      for (const { hexcode, phrasings: list } of await generate(batch)) {
        const existing = regenerateAll ? [] : (phrasings[hexcode] ?? []);
        phrasings[hexcode] = [...new Set([...existing, ...list.map((p) => p.trim().toLowerCase())])];
      }
    } catch (err) {
      console.error(`\nbatch failed (${batch[0].hexcode}…): ${err.message}`);
    }
    done += batch.length;
    process.stdout.write(`\r  ${done}/${todo.length}`);
    // Save as we go so a crash doesn't lose everything.
    writeFileSync(phrasingsPath, JSON.stringify(phrasings, null, 2) + '\n');
  }
}

await Promise.all(Array.from({ length: CONCURRENCY }, worker));
console.log('\ndone — now run: pnpm build');
