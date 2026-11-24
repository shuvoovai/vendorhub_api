// Usage: node prisma/seed-import.js [--if-empty] [--update]
// Loads prisma/seed-data/ (made by scripts/export-seed.js) WITHOUT deleting anything, so it is safe on a
// live database (Docker runs it on start):
//   default     insert only the rows that do not exist yet; existing rows are never changed
//   --if-empty  do nothing when the database already has users (first start only)
//   --update    also overwrite existing rows with the exported values (by id)
// Media files are copied into UPLOAD_DIR/media when missing. No export present: nothing happens.
import { PrismaClient } from '@prisma/client';
import { hasSeedData, importSeedData } from './seed-data-lib.js';

const args = new Set(process.argv.slice(2));
const prisma = new PrismaClient();
try {
  if (!(await hasSeedData())) {
    console.log('seed-import: no prisma/seed-data export, nothing to do');
  } else if (args.has('--if-empty') && (await prisma.user.count()) > 0) {
    console.log('seed-import: the database already has users, skipped');
  } else {
    const { counts, files } = await importSeedData(prisma, process.env.UPLOAD_DIR ?? './uploads', {
      mode: args.has('--update') ? 'update' : 'missing',
    });
    console.log('seed-import:', JSON.stringify({ ...counts, mediaFiles: files }));
    console.log('seed-import: run scripts/backfill-fingerprints.mjs to rebuild the visual search fingerprints');
  }
} finally {
  await prisma.$disconnect();
}
