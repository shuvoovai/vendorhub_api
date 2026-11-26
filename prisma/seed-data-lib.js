// Seed data from a real database: export (scripts/export-seed.js) and import (prisma/seed.js, prisma/seed-import.js).
//
// prisma/seed-data/ holds one JSON file per table plus media/ (the public /media files). It contains real
// accounts (emails, phones, bcrypt hashes), so it is git-ignored: copy it to another machine yourself.
//
// Never exported: refresh/reset/verification tokens, audit logs, carts, orders, payments, returns, reviews,
// bargains, notifications, idempotency keys, food orders, to-let inquiries, shop verification cases and their
// private documents (uploads/private). Vector fingerprints are not exported either: run
// scripts/backfill-fingerprints.mjs after an import.
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { mkdir, readdir, readFile, writeFile, copyFile, access } from 'node:fs/promises';

export const SEED_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), 'seed-data');
export const SEED_MEDIA_DIR = path.join(SEED_DIR, 'media');

// In foreign-key order. "later": columns that point "forward" (or at the same table); they are written
// as null first and set in a second pass, once every row exists. key: the primary key (composite for joins).
// defaults: values for columns that an older export does not have yet.
export const TABLES = [
  { model: 'user' },
  { model: 'market', later: ['imageId'] },
  { model: 'category', later: ['parentId'] },
  { model: 'brand' },
  { model: 'shop', later: ['logoImageId', 'bannerImageId'] },
  { model: 'address' },
  { model: 'shopStaff', key: ['shopId', 'userId'] },
  { model: 'shopFollow', key: ['shopId', 'userId'] },
  { model: 'product' },
  { model: 'image' },
  { model: 'fileUpload' },
  { model: 'shopPhoto' },
  { model: 'shopListing' },
  { model: 'listingVariant' },
  { model: 'banner' },
  { model: 'flashDeal', defaults: { status: 'APPROVED' } }, // exports made before deal approval: they were live
  { model: 'foodItem' },
  { model: 'tolet' },
];

const fileOf = (model) => path.join(SEED_DIR, `${model}.json`);
const exists = (p) => access(p).then(() => true, () => false);

/** True when an export is present. */
export const hasSeedData = () => exists(fileOf('user'));

// ---------- export ----------

/** Writes every table to prisma/seed-data/<model>.json and copies the public media files. */
export async function exportSeedData(prisma, uploadDir) {
  await mkdir(SEED_MEDIA_DIR, { recursive: true });
  const counts = {};
  for (const { model } of TABLES) {
    const rows = await prisma[model].findMany();
    await writeFile(fileOf(model), `${JSON.stringify(rows, null, 1)}\n`);
    counts[model] = rows.length;
  }
  // only the public, already re-encoded files; private verification documents stay out
  const mediaDir = path.resolve(uploadDir, 'media');
  let files = 0;
  if (await exists(mediaDir)) {
    for (const name of await readdir(mediaDir)) {
      await copyFile(path.join(mediaDir, name), path.join(SEED_MEDIA_DIR, name));
      files++;
    }
  }
  return { counts, files };
}

// ---------- import ----------

const pick = (row, keys) => Object.fromEntries(keys.map((k) => [k, row[k]]));
const whereOf = (t, row) => (t.key ? { [t.key.join('_')]: pick(row, t.key) } : { id: row.id });

/**
 * Loads the export. mode "update": insert or overwrite every row by its key (prisma/seed.js, after clean()).
 * mode "missing": insert only rows that do not exist yet, never change existing ones (safe on a live
 * database; used by Docker). Copies media files that are missing. Returns counts per table.
 */
export async function importSeedData(prisma, uploadDir, { mode = 'missing' } = {}) {
  const counts = {};
  const deferred = [];
  for (const t of TABLES) {
    if (!(await exists(fileOf(t.model)))) continue;
    const rows = JSON.parse(await readFile(fileOf(t.model), 'utf8')).map((row) => ({ ...t.defaults, ...row }));
    const later = t.later ?? [];
    const first = (row) => ({ ...row, ...Object.fromEntries(later.map((k) => [k, null])) });
    let written = rows;
    if (mode === 'update') {
      for (const row of rows) {
        // an existing row keeps its forward links until the second pass sets them
        const { [later[0]]: _a, [later[1]]: _b, ...update } = row;
        await prisma[t.model].upsert({ where: whereOf(t, row), create: first(row), update: later.length ? update : row });
      }
    } else {
      // skipDuplicates: a row whose id (or any unique value) already exists is left alone
      const created = rows.length ? await prisma[t.model].createManyAndReturn({ data: rows.map(first), skipDuplicates: true }) : [];
      const ids = new Set(created.map((r) => (t.key ? t.key.map((k) => r[k]).join('|') : r.id)));
      written = rows.filter((r) => ids.has(t.key ? t.key.map((k) => r[k]).join('|') : r.id));
    }
    counts[t.model] = written.length;
    for (const row of written) {
      const links = Object.fromEntries(later.filter((k) => row[k] != null).map((k) => [k, row[k]]));
      if (Object.keys(links).length) deferred.push({ t, row, links });
    }
  }
  for (const { t, row, links } of deferred) {
    await prisma[t.model].update({ where: whereOf(t, row), data: links });
  }

  // media files: copied when missing, never overwritten
  let files = 0;
  if (await exists(SEED_MEDIA_DIR)) {
    const mediaDir = path.resolve(uploadDir, 'media');
    await mkdir(mediaDir, { recursive: true });
    for (const name of await readdir(SEED_MEDIA_DIR)) {
      const target = path.join(mediaDir, name);
      if (await exists(target)) continue;
      await copyFile(path.join(SEED_MEDIA_DIR, name), target);
      files++;
    }
  }
  return { counts, files };
}
