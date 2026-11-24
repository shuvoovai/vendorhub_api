// Usage: node --env-file=.env scripts/make-test-tolet.mjs <approved|pending|expired>
//        node --env-file=.env scripts/make-test-tolet.mjs delete <toletId>
// Creates a to-let in the given state (prints its id) or deletes one, for test-tolet-inquiries.ps1. Dev only.
import { PrismaClient } from '@prisma/client';

if (process.env.NODE_ENV === 'production') {
  console.error('Refusing to run with NODE_ENV=production');
  process.exit(1);
}
const prisma = new PrismaClient();
const [mode, id] = process.argv.slice(2);
const DAY = 24 * 60 * 60 * 1000;

if (mode === 'delete') {
  await prisma.tolet.delete({ where: { id } });
  console.log(id);
} else {
  const expiresAt = { approved: new Date(Date.now() + 60 * DAY), expired: new Date(Date.now() - 1000), pending: null }[mode];
  if (expiresAt === undefined) {
    console.error('mode must be approved, pending, expired or delete');
    process.exit(1);
  }
  const t = await prisma.tolet.create({
    data: {
      type: 'SHOWROOM',
      title: `Test showroom (${mode})`,
      marketName: 'Jamuna Future Park',
      area: 'Kuril',
      address: 'Level 3, Jamuna Future Park, Kuril, Dhaka',
      rent: 60000,
      availableFrom: new Date(Date.now() + 7 * DAY),
      contactName: 'Rahim Uddin',
      contactPhone: '01711000222',
      status: mode === 'pending' ? 'PENDING' : 'APPROVED',
      expiresAt,
    },
  });
  console.log(t.id);
}
await prisma.$disconnect();
