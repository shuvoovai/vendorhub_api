// Flash deal pricing, shared by the cart, checkout, product page and the public deals list.
// The price is ALWAYS computed here on the server; a client never sends a price.
import { Prisma } from '@prisma/client';

// "Running" = active, started, not ended, and (with a stock limit) units left at the deal price.
export const runningDealWhere = (now = new Date()) => ({
  isActive: true,
  startsAt: { lte: now },
  endsAt: { gt: now },
});

const hasUnitsLeft = (deal, quantity = 1) => deal.stockLimit === null || deal.soldQty + quantity <= deal.stockLimit;

/**
 * The running deal of each listing (at most one per listing), or nothing.
 * @param db prisma client or transaction
 * @returns {Promise<Map<string, { id: string, dealPrice: number, endsAt: Date, stockLimit: number|null, soldQty: number }>>}
 */
export async function runningDeals(db, listingIds, now = new Date()) {
  if (listingIds.length === 0) return new Map();
  const rows = await db.flashDeal.findMany({
    where: { listingId: { in: listingIds }, ...runningDealWhere(now) },
    select: { id: true, listingId: true, dealPrice: true, endsAt: true, stockLimit: true, soldQty: true },
    orderBy: { dealPrice: 'asc' },
  });
  const map = new Map();
  for (const r of rows) if (!map.has(r.listingId)) map.set(r.listingId, r);
  return map;
}

/**
 * The unit price of a cart line: the lowest of the listing price, a running deal (when enough
 * deal units are left for this quantity) and an accepted bargain for this customer.
 */
export function unitPriceFor({ listingPrice, deal, quantity, bargainPrice }) {
  let price = listingPrice;
  let dealApplied = false;
  if (deal && deal.dealPrice < price && hasUnitsLeft(deal, quantity)) {
    price = deal.dealPrice;
    dealApplied = true;
  }
  if (bargainPrice != null && bargainPrice < price) {
    price = bargainPrice;
    dealApplied = false;
  }
  return { unitPrice: price, dealApplied };
}

/**
 * The price a customer pays right now for ONE unit of a listing (no bargain): the running deal
 * price while a deal runs (with units left), else the listing price. Offers are based on this.
 * @param listing { id, price }
 */
export async function currentPrice(db, listing, now = new Date()) {
  const deal = (await runningDeals(db, [listing.id], now)).get(listing.id);
  const { unitPrice, dealApplied } = unitPriceFor({ listingPrice: listing.price, deal, quantity: 1, bargainPrice: null });
  return { price: unitPrice, dealApplied };
}

/**
 * Claims deal units inside the checkout transaction. Safe when two customers buy the last
 * deal units at the same time: the condition is checked by the UPDATE itself.
 * @returns {Promise<boolean>} false when the deal ended or sold out meanwhile
 */
export async function claimDealUnits(tx, dealId, quantity) {
  const count = await tx.$executeRaw(Prisma.sql`
    UPDATE "FlashDeal"
       SET "soldQty" = "soldQty" + ${quantity}, "updatedAt" = now()
     WHERE id = ${dealId}
       AND "isActive" = true AND "startsAt" <= now() AND "endsAt" > now()
       AND ("stockLimit" IS NULL OR "soldQty" + ${quantity} <= "stockLimit")`);
  return count === 1;
}
