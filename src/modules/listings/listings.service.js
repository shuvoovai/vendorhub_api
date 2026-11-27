import { prisma } from '../../lib/prisma.js';
import { AppError } from '../../lib/errors.js';
import { assertShopAccess } from '../../lib/shopAccess.js';
import { checkVariants, deriveAvailability } from '../../lib/variants.js';
import { assertCanAddListing } from '../../lib/plans.js';

export { deriveAvailability };

// Who may see the stock number is a shop decision worth tracing: audited on every change.
const auditVisibility = (user, listing, from) =>
  prisma.auditLog.create({
    data: {
      actorId: user.id,
      action: 'listing.stock_visibility_changed',
      entityType: 'ShopListing',
      entityId: listing.id,
      meta: { shopId: listing.shopId, from, to: listing.stockVisibility },
    },
  });

const productSelect = {
  select: { id: true, slug: true, title: true, msrp: true, images: true },
};
// The owner view includes private fields: stockQty, minOfferPercent, isActive, and every variant.
const ownerInclude = {
  product: productSelect,
  variants: {
    orderBy: [{ isActive: 'desc' }, { createdAt: 'asc' }],
    select: { id: true, options: true, price: true, stockQty: true, isActive: true },
  },
};

export async function listShopListings(user, shopId) {
  await assertShopAccess(user, shopId);
  return prisma.shopListing.findMany({
    where: { shopId },
    orderBy: { createdAt: 'desc' },
    include: ownerInclude,
  });
}

/**
 * Applies variantOptions + variants (when sent) and keeps the stock consistent:
 * combinations are upserted by optionsKey (existing ids stay, so carts and orders keep pointing at them),
 * combinations no longer sent are set inactive (never deleted); [] and [] turn variants off.
 * With active variants and counted stock, the listing's stockQty is the sum of the active variants' stock.
 */
async function syncVariants(tx, listing, input) {
  const countsStock = listing.stockQty !== null;
  if (input.variantOptions !== undefined) {
    const { options, variants } = checkVariants(input.variantOptions, input.variants, { countsStock });
    const existing = await tx.listingVariant.findMany({ where: { listingId: listing.id }, select: { id: true, optionsKey: true } });
    const byKey = new Map(existing.map((v) => [v.optionsKey, v.id]));
    const sent = new Set();
    for (const v of variants) {
      sent.add(v.optionsKey);
      const id = byKey.get(v.optionsKey);
      if (id) await tx.listingVariant.update({ where: { id }, data: v });
      else await tx.listingVariant.create({ data: { ...v, listingId: listing.id } });
    }
    const gone = existing.filter((v) => !sent.has(v.optionsKey)).map((v) => v.id);
    if (gone.length) await tx.listingVariant.updateMany({ where: { id: { in: gone } }, data: { isActive: false } });
    await tx.shopListing.update({ where: { id: listing.id }, data: { variantOptions: options } });
  } else if (!countsStock) {
    // the listing stopped counting stock: so do its variants
    await tx.listingVariant.updateMany({ where: { listingId: listing.id, stockQty: { not: null } }, data: { stockQty: null } });
  }

  const active = await tx.listingVariant.findMany({ where: { listingId: listing.id, isActive: true }, select: { stockQty: true } });
  if (active.length && countsStock) {
    if (active.some((v) => v.stockQty === null)) {
      throw new AppError(400, 'This listing counts stock: send the variants with a stockQty');
    }
    const total = active.reduce((sum, v) => sum + v.stockQty, 0);
    await tx.shopListing.update({ where: { id: listing.id }, data: { stockQty: total, availability: deriveAvailability(total) } });
  }
  return tx.shopListing.findUnique({ where: { id: listing.id }, include: ownerInclude });
}

export async function createListing(user, shopId, input) {
  await assertShopAccess(user, shopId);

  const product = await prisma.product.findFirst({ where: { id: input.productId, isActive: true } });
  if (!product) throw new AppError(404, 'Product not found');

  const existing = await prisma.shopListing.findUnique({
    where: { shopId_productId: { shopId, productId: input.productId } },
  });
  if (existing?.isActive) throw new AppError(409, 'This shop already lists this product');

  const data = {
    price: input.price,
    stockQty: input.stockQty ?? null,
    availability: input.availability ?? deriveAvailability(input.stockQty),
    bargainEnabled: input.bargainEnabled,
    minOfferPercent: input.minOfferPercent,
    ...(input.stockVisibility && { stockVisibility: input.stockVisibility }),
  };

  const listing = await prisma.$transaction(async (tx) => {
    await assertCanAddListing(tx, shopId); // FREE plan: at most maxListings active listings (403 PLAN_LIMIT)
    // A previously removed listing is re-activated instead of creating a duplicate
    const l = existing
      ? await tx.shopListing.update({ where: { id: existing.id }, data: { ...data, isActive: true } })
      : await tx.shopListing.create({ data: { shopId, productId: input.productId, ...data } });
    return syncVariants(tx, l, input);
  });
  if (input.stockVisibility && input.stockVisibility !== (existing?.stockVisibility ?? 'HIDDEN')) {
    await auditVisibility(user, listing, existing?.stockVisibility ?? null);
  }
  return listing;
}

export async function updateListing(user, shopId, listingId, input) {
  await assertShopAccess(user, shopId);

  const listing = await prisma.shopListing.findFirst({ where: { id: listingId, shopId } });
  if (!listing) throw new AppError(404, 'Listing not found');

  const { variantOptions, variants, ...fields } = input;
  const data = { ...fields };
  if (fields.stockQty !== undefined && fields.availability === undefined) {
    data.availability = deriveAvailability(fields.stockQty);
  }
  const updated = await prisma.$transaction(async (tx) => {
    // re-activating counts against the plan's listing limit; existing active listings are never touched
    if (fields.isActive === true && !listing.isActive) await assertCanAddListing(tx, shopId);
    const l = await tx.shopListing.update({ where: { id: listingId }, data });
    return syncVariants(tx, l, { variantOptions, variants });
  });
  if (fields.stockVisibility && fields.stockVisibility !== listing.stockVisibility) {
    await auditVisibility(user, updated, listing.stockVisibility);
  }
  return updated;
}

// Soft delete: orders reference listings, so we deactivate instead of deleting.
export async function removeListing(user, shopId, listingId) {
  await assertShopAccess(user, shopId);

  const listing = await prisma.shopListing.findFirst({ where: { id: listingId, shopId } });
  if (!listing) throw new AppError(404, 'Listing not found');

  await prisma.shopListing.update({ where: { id: listingId }, data: { isActive: false } });
}
