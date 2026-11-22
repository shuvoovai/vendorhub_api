// Demo data for the home page "Flash deals" section: creates 4 running deals (ending in 2-48 hours)
// on existing in-stock listings of verified shops, one product each. DEVELOPMENT ONLY.
//
//   npm run seed:deals            (= node --env-file=.env scripts/seed-flash-deals.mjs)
//
// Safe to run again: does nothing while 4 or more deals are running, and skips products that
// already have an active deal (now or later).
// The deals follow the same rules as the API (lower than the listing price, at most 7 days long)
// and every one is written to the audit log.
import { prisma } from '../src/lib/prisma.js';

if (process.env.NODE_ENV === 'production') {
  console.error('Refusing to run: NODE_ENV=production. This script creates demo deals for development only.');
  process.exit(1);
}

const HOURS = [2, 9, 26, 48]; // when each deal ends, from now
const DISCOUNTS = [0.85, 0.8, 0.9, 0.75]; // deal price as a share of the listing price

try {
  const now = new Date();
  const running = await prisma.flashDeal.count({ where: { isActive: true, startsAt: { lte: now }, endsAt: { gt: now } } });
  if (running >= HOURS.length) {
    console.log(`${running} flash deals are already running; nothing to do.`);
    process.exit(0);
  }
  const candidates = await prisma.shopListing.findMany({
    where: {
      isActive: true,
      availability: { not: 'OUT_OF_STOCK' },
      price: { gte: 100 },
      shop: { isActive: true, verificationLevel: { not: 'UNVERIFIED' } },
      // skip products that already have an active deal (now or later) on any listing
      product: { isActive: true, listings: { none: { flashDeals: { some: { isActive: true, endsAt: { gt: now } } } } } },
    },
    select: { id: true, price: true, productId: true, shop: { select: { ownerId: true } }, product: { select: { title: true } } },
    orderBy: [{ price: 'desc' }, { id: 'asc' }],
  });

  // one deal per product, so the home page shows four different products
  const picked = [];
  const seen = new Set();
  for (const l of candidates) {
    if (seen.has(l.productId)) continue;
    seen.add(l.productId);
    picked.push(l);
    if (picked.length === HOURS.length) break;
  }
  if (picked.length === 0) {
    console.log('No suitable listings found (run "node --env-file=.env prisma/seed.js" first, or every listing already has a deal).');
    process.exit(0);
  }

  for (const [i, l] of picked.entries()) {
    const dealPrice = Math.max(1, Math.min(l.price - 1, Math.round(l.price * DISCOUNTS[i])));
    const endsAt = new Date(now.getTime() + HOURS[i] * 60 * 60 * 1000);
    await prisma.$transaction(async (tx) => {
      const d = await tx.flashDeal.create({
        data: { listingId: l.id, dealPrice, startsAt: new Date(now.getTime() - 60 * 1000), endsAt, createdById: l.shop.ownerId },
      });
      await tx.auditLog.create({
        data: { actorId: l.shop.ownerId, action: 'deal.created', entityType: 'FlashDeal', entityId: d.id, meta: { listingId: l.id, dealPrice, source: 'seed-flash-deals' } },
      });
    });
    console.log(`Deal: ${l.product.title}  ${l.price} -> ${dealPrice} BDT, ends in ${HOURS[i]} h`);
  }
  console.log(`${picked.length} flash deal(s) created. GET /api/v1/deals/flash shows them (cached up to 60 s).`);
} finally {
  await prisma.$disconnect();
}
