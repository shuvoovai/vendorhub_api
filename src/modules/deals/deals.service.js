import { Prisma } from '@prisma/client';
import { prisma } from '../../lib/prisma.js';
import { AppError } from '../../lib/errors.js';
import { assertShopAccess } from '../../lib/shopAccess.js';
import { listProducts } from '../catalog/catalog.service.js';
import { MAX_DEAL_DAYS } from './deals.schema.js';

const NOT_FOUND = 'Deal not found';
const MAX_MS = MAX_DEAL_DAYS * 24 * 60 * 60 * 1000;

const audit = (db, actorId, action, entityId, meta) =>
  db.auditLog.create({ data: { actorId, action, entityType: 'FlashDeal', entityId, meta } });

const present = (d) => ({
  id: d.id,
  listingId: d.listingId,
  dealPrice: d.dealPrice,
  startsAt: d.startsAt,
  endsAt: d.endsAt,
  isActive: d.isActive,
  stockLimit: d.stockLimit,
  soldQty: d.soldQty,
  createdAt: d.createdAt,
  updatedAt: d.updatedAt,
  ...(d.listing && {
    listing: {
      id: d.listing.id,
      price: d.listing.price,
      shop: d.listing.shop,
      product: d.listing.product,
    },
  }),
});
const listingInclude = {
  listing: {
    select: {
      id: true,
      price: true,
      shop: { select: { id: true, name: true, slug: true } },
      product: { select: { id: true, slug: true, title: true } },
    },
  },
};

// ---------- public ----------

// Running deals (in stock, units left, still cheaper than the listing, VERIFIED active shop), one per
// product (the cheapest deal), soonest-ending first. Each item is a normal product card + the deal.
// No stock number is ever included here (cards carry availability only), whatever the stockVisibility.
export async function listFlash({ limit }) {
  const rows = await prisma.$queryRaw`
    SELECT * FROM (
      SELECT DISTINCT ON (l."productId")
             d.id AS "dealId", d."listingId", d."dealPrice", d."endsAt", l.price AS "originalPrice", l."productId"
      FROM "FlashDeal" d
      JOIN "ShopListing" l ON l.id = d."listingId"
      JOIN "Shop" s ON s.id = l."shopId"
      JOIN "Product" p ON p.id = l."productId"
      WHERE d."isActive" = true AND d."startsAt" <= now() AND d."endsAt" > now()
        AND (d."stockLimit" IS NULL OR d."soldQty" < d."stockLimit")
        AND d."dealPrice" < l.price
        AND l."isActive" = true AND l.availability <> 'OUT_OF_STOCK'
        AND s."isActive" = true AND s."verificationLevel" <> 'UNVERIFIED' AND p."isActive" = true
      ORDER BY l."productId", d."dealPrice" ASC, d."endsAt" ASC
    ) x
    ORDER BY x."endsAt" ASC, x."dealId" ASC
    LIMIT ${limit}`;
  if (rows.length === 0) return [];

  const productIds = rows.map((r) => r.productId);
  const { items } = await listProducts({ productIds, sort: 'newest', page: 1, limit: productIds.length });
  const cards = new Map(items.map((c) => [c.id, c]));

  return rows
    .filter((r) => cards.has(r.productId))
    .map((r) => ({
      ...cards.get(r.productId),
      dealPrice: r.dealPrice,
      originalPrice: r.originalPrice,
      dealEndsAt: r.endsAt.toISOString(),
      dealId: r.dealId,
      listingId: r.listingId,
    }));
}

// ---------- shop team ----------

// Locks the listing row for this transaction, so two requests cannot both create a deal for it.
async function lockListing(tx, shopId, listingId) {
  const rows = await tx.$queryRaw(Prisma.sql`
    SELECT id, price FROM "ShopListing" WHERE id = ${listingId} AND "shopId" = ${shopId} FOR UPDATE`);
  if (rows.length === 0) throw new AppError(404, 'Listing not found');
  return rows[0];
}

function checkDeal({ dealPrice, startsAt, endsAt }, listingPrice) {
  if (dealPrice >= listingPrice) throw new AppError(400, 'The deal price must be lower than the listing price');
  if (endsAt <= startsAt || endsAt - startsAt > MAX_MS) {
    throw new AppError(400, `endsAt must be after startsAt and at most ${MAX_DEAL_DAYS} days later`);
  }
  if (endsAt <= new Date()) throw new AppError(400, 'endsAt must be in the future');
}

// One active deal per listing at a time: no other active deal may overlap this time window.
async function assertNoOverlap(tx, listingId, { startsAt, endsAt }, exceptId) {
  const other = await tx.flashDeal.findFirst({
    where: {
      listingId,
      isActive: true,
      startsAt: { lt: endsAt },
      endsAt: { gt: startsAt },
      ...(exceptId && { id: { not: exceptId } }),
    },
    select: { id: true },
  });
  if (other) throw new AppError(409, 'This listing already has an active deal in that period');
}

export async function listForShop(user, shopId) {
  await assertShopAccess(user, shopId);
  const rows = await prisma.flashDeal.findMany({
    where: { listing: { shopId } },
    include: listingInclude,
    orderBy: [{ endsAt: 'desc' }, { id: 'asc' }],
  });
  return rows.map(present);
}

export async function create(user, shopId, input) {
  await assertShopAccess(user, shopId);
  const deal = await prisma.$transaction(async (tx) => {
    const listing = await lockListing(tx, shopId, input.listingId);
    checkDeal(input, listing.price);
    const isActive = input.isActive ?? true;
    if (isActive) await assertNoOverlap(tx, listing.id, input);
    const d = await tx.flashDeal.create({
      data: { ...input, isActive, createdById: user.id },
      include: listingInclude,
    });
    await audit(tx, user.id, 'deal.created', d.id, { shopId, listingId: d.listingId, dealPrice: d.dealPrice });
    return d;
  });
  return present(deal);
}

async function findShopDeal(db, shopId, id) {
  const deal = await db.flashDeal.findFirst({ where: { id, listing: { shopId } } });
  if (!deal) throw new AppError(404, NOT_FOUND); // another shop's deal: 404, not 403
  return deal;
}

export async function update(user, shopId, id, input) {
  await assertShopAccess(user, shopId);
  const deal = await prisma.$transaction(async (tx) => {
    const current = await findShopDeal(tx, shopId, id);
    const listing = await lockListing(tx, shopId, current.listingId);
    const merged = { ...current, ...input };
    checkDeal(merged, listing.price);
    if (merged.isActive) await assertNoOverlap(tx, listing.id, merged, id);
    const d = await tx.flashDeal.update({ where: { id }, data: input, include: listingInclude });
    await audit(tx, user.id, 'deal.updated', id, { shopId, fields: Object.keys(input) });
    return d;
  });
  return present(deal);
}

export async function remove(user, shopId, id) {
  await assertShopAccess(user, shopId);
  await prisma.$transaction(async (tx) => {
    const deal = await findShopDeal(tx, shopId, id);
    await tx.flashDeal.delete({ where: { id } });
    await audit(tx, user.id, 'deal.deleted', id, { shopId, listingId: deal.listingId });
  });
}

// ---------- admin ----------

export async function listAll({ page, limit }) {
  const [rows, total] = await prisma.$transaction([
    prisma.flashDeal.findMany({
      include: listingInclude,
      orderBy: [{ endsAt: 'desc' }, { id: 'asc' }],
      skip: (page - 1) * limit,
      take: limit,
    }),
    prisma.flashDeal.count(),
  ]);
  return { items: rows.map(present), pagination: { page, limit, total, totalPages: Math.ceil(total / limit) } };
}

export async function adminRemove(admin, id) {
  await prisma.$transaction(async (tx) => {
    const deal = await tx.flashDeal.findUnique({ where: { id }, include: { listing: { select: { shopId: true } } } });
    if (!deal) throw new AppError(404, NOT_FOUND);
    await tx.flashDeal.delete({ where: { id } });
    await audit(tx, admin.id, 'deal.admin_deleted', id, { shopId: deal.listing.shopId, listingId: deal.listingId });
  });
}
