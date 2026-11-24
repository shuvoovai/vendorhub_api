// Usage: node --env-file=.env scripts/export-seed.js     (or: npm run seed:export)
// Exports the current database (users, shops, markets, categories, brands, products, images, listings,
// variants, banners, flash deals, food items, to-lets) to prisma/seed-data/*.json and copies the public
// media files to prisma/seed-data/media/. Read-only on the database.
//
// The export holds real accounts (emails, phones, bcrypt password hashes; never plain passwords) and is
// git-ignored: do not commit it to the public repository. See prisma/seed-data-lib.js for what is left out.
import { PrismaClient } from '@prisma/client';
import { exportSeedData, SEED_DIR } from '../prisma/seed-data-lib.js';

const prisma = new PrismaClient();
try {
  const { counts, files } = await exportSeedData(prisma, process.env.UPLOAD_DIR ?? './uploads');
  for (const [model, n] of Object.entries(counts)) console.log(`${model.padEnd(15)} ${n}`);
  console.log(`media files     ${files}`);
  console.log(`written to ${SEED_DIR}`);
} finally {
  await prisma.$disconnect();
}
