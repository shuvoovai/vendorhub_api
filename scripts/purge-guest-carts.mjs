// Usage: node --env-file=.env scripts/purge-guest-carts.mjs [--backdate-all]
// Deletes guest carts not used for 30 days (the API also does this hourly) and prints how many.
// --backdate-all (dev only, for tests): first marks EVERY guest cart as unused for 31 days.
import { prisma } from '../src/lib/prisma.js';
import { purgeStaleGuestCarts } from '../src/modules/cart/cart.service.js';

if (process.argv.includes('--backdate-all')) {
  if (process.env.NODE_ENV === 'production') {
    console.error('Refusing --backdate-all with NODE_ENV=production');
    process.exit(1);
  }
  await prisma.cart.updateMany({ where: { userId: null }, data: { lastUsedAt: new Date(Date.now() - 31 * 24 * 60 * 60 * 1000) } });
}
console.log(await purgeStaleGuestCarts());
await prisma.$disconnect();
