// Usage: node --env-file=.env scripts/expire-tolet.mjs <toletId>
// Moves an approved to-let's expiry into the past so the public list can be tested without waiting 60 days.
import { PrismaClient } from '@prisma/client';

const prisma = new PrismaClient();
const id = process.argv[2];
await prisma.tolet.update({ where: { id }, data: { expiresAt: new Date(Date.now() - 1000) } });
await prisma.$disconnect();
console.log('expired', id);
