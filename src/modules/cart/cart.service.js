import crypto from 'node:crypto';
import { prisma } from '../../lib/prisma.js';
import { AppError } from '../../lib/errors.js';
import { runningDeals, unitPriceFor } from '../../lib/deals.js';
import { loadViewer, visibleStockQty } from '../../lib/stockVisibility.js';

const MAX_QTY_PER_LINE = 10;
const DAY = 24 * 60 * 60 * 1000;
export const GUEST_CART_DAYS = 30;

// Every function takes an owner: { userId } for a logged-in user, or { cartId } for a guest cart
// (found only through the httpOnly cookie, see findGuestCart). A guest with no cart yet is null.
const cartWhere = (owner) => (owner.userId ? { userId: owner.userId } : { id: owner.cartId });

const shopSelect = {
  id: true,
  name: true,
  slug: true,
  logoUrl: true,
  levelFloor: true,
  shopNumber: true,
  addressLine: true,
  verificationLevel: true,
  supportsDelivery: true,
  supportsPickup: true,
  isActive: true,
  market: { select: { name: true, slug: true } },
};

const EMPTY_CART = Object.freeze({ shops: [], totals: { itemCount: 0, shopCount: 0, subtotal: 0, checkoutReady: false } });

// ---------- guest carts ----------

// The cookie holds a random UUID; only its SHA-256 is stored, so a database leak reveals no usable cart key.
const hashToken = (token) => crypto.createHash('sha256').update(token).digest('hex');
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** The guest cart for a cookie value, or null (missing, malformed or unknown). Marks it as used. */
export async function findGuestCart(token) {
  if (typeof token !== 'string' || !UUID.test(token)) return null;
  const cart = await prisma.cart.findUnique({ where: { guestTokenHash: hashToken(token) }, select: { id: true, lastUsedAt: true } });
  if (!cart) return null;
  // at most one write per hour per cart, so reads stay cheap
  if (Date.now() - cart.lastUsedAt.getTime() > 60 * 60 * 1000) {
    await prisma.cart.update({ where: { id: cart.id }, data: { lastUsedAt: new Date() } });
  }
  return { cartId: cart.id };
}

/** Creates a guest cart; returns the owner and the new cookie value. */
export async function createGuestCart() {
  const token = crypto.randomUUID();
  const cart = await prisma.cart.create({ data: { guestTokenHash: hashToken(token) }, select: { id: true } });
  return { owner: { cartId: cart.id }, token };
}

/** Job: deletes guest carts not used for 30 days (their items go with them). */
export async function purgeStaleGuestCarts() {
  const { count } = await prisma.cart.deleteMany({
    where: { userId: null, lastUsedAt: { lt: new Date(Date.now() - GUEST_CART_DAYS * DAY) } },
  });
  return count;
}

// ---------- shared rules ----------

// stockQty is private: we enforce it but never reveal the number.
function assertQuantity(listing, qty) {
  if (qty > MAX_QTY_PER_LINE) {
    throw new AppError(400, `You can buy at most ${MAX_QTY_PER_LINE} of one item at a time`);
  }
  if (listing.stockQty !== null && qty > listing.stockQty) {
    throw new AppError(409, 'Not enough stock for that quantity');
  }
}

// 404 (not 403) for someone else's item, so item ids cannot be probed
async function findOwnItem(owner, itemId) {
  const item = owner && (await prisma.cartItem.findFirst({ where: { id: itemId, cart: cartWhere(owner) }, include: { listing: true } }));
  if (!item) throw new AppError(404, 'Cart item not found');
  return item;
}

// The cart grouped by shop, with live prices and per-item problem flags.
export async function getCart(owner) {
  if (!owner) return structuredClone(EMPTY_CART);
  const userId = owner.userId ?? null;
  const cart = await prisma.cart.findUnique({
    where: cartWhere(owner),
    include: {
      items: {
        include: {
          listing: {
            include: {
              product: { select: { id: true, slug: true, title: true, images: true, msrp: true } },
              shop: { select: shopSelect },
            },
          },
          bargain: { select: { status: true, agreedPrice: true, customerId: true } },
        },
      },
    },
  });

  const groups = new Map();
  let itemCount = 0;
  let hasProblem = false;
  const deals = await runningDeals(prisma, (cart?.items ?? []).map((i) => i.listingId));
  const viewer = userId && cart?.items.length ? await loadViewer({ id: userId }) : null;

  for (const item of cart?.items ?? []) {
    const l = item.listing;

    let problem = null;
    if (!l.isActive || !l.shop.isActive) problem = 'UNAVAILABLE';
    else if (l.availability === 'OUT_OF_STOCK') problem = 'OUT_OF_STOCK';
    else if (l.stockQty !== null && item.quantity > l.stockQty) problem = 'INSUFFICIENT_STOCK';

    // An accepted bargain for this customer overrides the listing price (guests never have one)
    const bargainApplied = Boolean(
      userId && item.bargain && item.bargain.status === 'ACCEPTED' && item.bargain.agreedPrice && item.bargain.customerId === userId,
    );
    // the lowest of: listing price, running flash deal, accepted bargain (never more than the listing price)
    const deal = deals.get(l.id);
    const { unitPrice, dealApplied } = unitPriceFor({
      listingPrice: l.price,
      deal,
      quantity: item.quantity,
      bargainPrice: bargainApplied ? item.bargain.agreedPrice : null,
    });
    const lineTotal = unitPrice * item.quantity;

    if (!groups.has(l.shop.id)) {
      const { isActive, ...shop } = l.shop;
      groups.set(l.shop.id, { shop, items: [], subtotal: 0 });
    }
    const group = groups.get(l.shop.id);
    group.items.push({
      id: item.id,
      listingId: l.id,
      quantity: item.quantity,
      product: {
        id: l.product.id,
        slug: l.product.slug,
        title: l.product.title,
        image: l.product.images[0] ?? null,
      },
      msrp: l.product.msrp,
      unitPrice,
      lineTotal,
      availability: l.availability,
      stockQty: visibleStockQty(viewer, l), // null unless the listing's stockVisibility allows this user (guests: PUBLIC only)
      bargainApplied,
      dealApplied,
      dealEndsAt: dealApplied ? deal.endsAt : null,
      problem,
    });

    // items with a problem are shown but not counted in the subtotal
    if (!problem) group.subtotal += lineTotal;
    else hasProblem = true;
    itemCount += item.quantity;
  }

  const shops = [...groups.values()].sort((a, b) => a.shop.name.localeCompare(b.shop.name));
  return {
    shops,
    totals: {
      itemCount,
      shopCount: shops.length,
      subtotal: shops.reduce((sum, g) => sum + g.subtotal, 0),
      checkoutReady: itemCount > 0 && !hasProblem,
    },
  };
}

// A listing that can be put in a cart, or a 404/409.
async function buyableListing(listingId) {
  const listing = await prisma.shopListing.findUnique({
    where: { id: listingId },
    include: { shop: { select: { isActive: true } } },
  });
  if (!listing || !listing.isActive || !listing.shop.isActive) {
    throw new AppError(404, 'Listing not found');
  }
  if (listing.availability === 'OUT_OF_STOCK') {
    throw new AppError(409, 'This item is out of stock');
  }
  return listing;
}

/** Checks the listing first (so a guest cart is only created for a valid add). */
export const checkListing = buyableListing;

export async function addItem(owner, { listingId, quantity }) {
  const listing = await buyableListing(listingId);
  const cart = owner.userId
    ? await prisma.cart.upsert({ where: { userId: owner.userId }, update: {}, create: { userId: owner.userId } })
    : { id: owner.cartId };
  const existing = await prisma.cartItem.findUnique({
    where: { cartId_listingId: { cartId: cart.id, listingId } },
  });

  // adding the same listing again increases its quantity
  const newQty = (existing?.quantity ?? 0) + quantity;
  if (existing?.bargainId && newQty > 1) {
    throw new AppError(400, 'A bargained price applies to one unit only');
  }
  assertQuantity(listing, newQty);

  if (existing) {
    await prisma.cartItem.update({ where: { id: existing.id }, data: { quantity: newQty } });
  } else {
    await prisma.cartItem.create({ data: { cartId: cart.id, listingId, quantity: newQty } });
  }
  return getCart(owner);
}

export async function updateItem(owner, itemId, { quantity }) {
  const item = await findOwnItem(owner, itemId);
  if (item.bargainId && quantity > 1) {
    throw new AppError(400, 'A bargained price applies to one unit only');
  }
  // lowering the quantity is always allowed; raising it is checked against stock
  if (quantity > item.quantity) assertQuantity(item.listing, quantity);
  await prisma.cartItem.update({ where: { id: itemId }, data: { quantity } });
  return getCart(owner);
}

export async function removeItem(owner, itemId) {
  await findOwnItem(owner, itemId);
  await prisma.cartItem.delete({ where: { id: itemId } });
  return getCart(owner);
}

export async function clearCart(owner) {
  if (owner) await prisma.cartItem.deleteMany({ where: { cart: cartWhere(owner) } });
  return getCart(owner);
}

// ---------- merge (after login) ----------

/**
 * Moves a guest cart's items into the user's cart and deletes the guest cart, in one transaction.
 * Same listing: quantities are added, capped at 10 (and at the stock, when known); listings that are gone
 * or out of stock are skipped. Idempotent: the guest cart is deleted in the same transaction, and a second
 * (or parallel) call finds nothing to merge.
 * @returns {Promise<{ merged: number, skipped: number }>}
 */
export async function mergeGuestCart(userId, guest) {
  if (!guest) return { merged: 0, skipped: 0 };
  return prisma.$transaction(async (tx) => {
    const items = await tx.cartItem.findMany({
      where: { cartId: guest.cartId },
      include: { listing: { include: { shop: { select: { isActive: true } } } } },
    });
    // claim the guest cart first: a parallel merge waits on this row and then deletes nothing
    const { count } = await tx.cart.deleteMany({ where: { id: guest.cartId, userId: null } });
    if (count !== 1) return { merged: 0, skipped: 0 };

    const cart = await tx.cart.upsert({ where: { userId }, update: {}, create: { userId } });
    let merged = 0;
    let skipped = 0;
    for (const g of items) {
      const l = g.listing;
      const cap = Math.min(MAX_QTY_PER_LINE, l.stockQty ?? MAX_QTY_PER_LINE);
      if (!l.isActive || !l.shop.isActive || l.availability === 'OUT_OF_STOCK' || cap < 1) {
        skipped++;
        continue;
      }
      const existing = await tx.cartItem.findUnique({ where: { cartId_listingId: { cartId: cart.id, listingId: l.id } } });
      if (existing?.bargainId) {
        skipped++; // a bargained line stays at one unit
        continue;
      }
      const quantity = Math.min(cap, (existing?.quantity ?? 0) + g.quantity);
      if (existing) await tx.cartItem.update({ where: { id: existing.id }, data: { quantity } });
      else await tx.cartItem.create({ data: { cartId: cart.id, listingId: l.id, quantity } });
      merged++;
    }
    return { merged, skipped };
  });
}
