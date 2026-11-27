// Vendor subscriptions: a shop OWNER pays for Pro by bKash / Nagad to our merchant number and sends a
// request; an admin checks the merchant account and approves (Shop.proUntil is extended) or rejects it.
// walletNumber and transactionId are shown only to that owner and to admins, and never logged
// (audit log entries and notifications leave them out).
import { Prisma } from '@prisma/client';
import { prisma } from '../../lib/prisma.js';
import { env } from '../../config/env.js';
import { AppError } from '../../lib/errors.js';
import { PLANS, PLAN_CODES, proPrice } from '../../config/plans.js';
import { extendProUntil, isPro } from '../../lib/plans.js';
import { notifySubscriptionRequested, notifySubscriptionReview } from '../notifications/notifications.events.js';

const NOT_FOUND = 'Subscription request not found';
const MERCHANT = { BKASH: () => env.BKASH_MERCHANT_NUMBER, NAGAD: () => env.NAGAD_MERCHANT_NUMBER };

const audit = (db, actorId, action, entityId, meta) =>
  db.auditLog.create({ data: { actorId, action, entityType: 'SubscriptionRequest', entityId, meta } });

const present = (r) => ({
  id: r.id,
  plan: r.plan,
  months: r.months,
  amount: r.amount,
  method: r.method,
  walletNumber: r.walletNumber,
  transactionId: r.transactionId,
  status: r.status,
  rejectReason: r.rejectReason ?? null,
  createdAt: r.createdAt,
  reviewedAt: r.reviewedAt ?? null,
});
const shopSelect = { shop: { select: { id: true, name: true, slug: true } } };
const presentAdmin = (r) => ({ ...present(r), shop: r.shop });

// ---------- public ----------

export const listPlans = () =>
  PLAN_CODES.map((code) => {
    const p = PLANS[code];
    return {
      code: p.code,
      maxListings: p.maxListings,
      flashDeals: p.flashDeals,
      featuredBadge: p.featuredBadge,
      prices: p.prices.map(({ months, amount }) => ({ months, amount })),
    };
  });

// ---------- shop owner ----------

// Only the shop's OWNER (from the session, never from the shopId alone). Staff: 403; anyone else: 404.
async function assertOwner(user, shopId) {
  const shop = await prisma.shop.findUnique({
    where: { id: shopId },
    select: { id: true, ownerId: true, proUntil: true, staff: { where: { userId: user.id }, select: { userId: true } } },
  });
  if (!shop) throw new AppError(404, 'Shop not found');
  if (shop.ownerId === user.id) return shop;
  if (shop.staff.length > 0) throw new AppError(403, 'Only the shop owner can manage the subscription');
  throw new AppError(404, 'Shop not found');
}

export async function getSubscription(user, shopId) {
  const shop = await assertOwner(user, shopId);
  const [listingsUsed, pending, lastApproved, rejected] = await Promise.all([
    prisma.shopListing.count({ where: { shopId, isActive: true } }),
    prisma.subscriptionRequest.findFirst({ where: { shopId, status: 'PENDING' }, orderBy: { createdAt: 'desc' } }),
    prisma.subscriptionRequest.findFirst({
      where: { shopId, status: 'APPROVED' },
      orderBy: { reviewedAt: 'desc' },
      select: { reviewedAt: true },
    }),
    prisma.subscriptionRequest.findFirst({ where: { shopId, status: 'REJECTED' }, orderBy: { reviewedAt: 'desc' } }),
  ]);
  const pro = isPro(shop.proUntil);
  // a rejection matters only until a later request is approved
  const showRejected = rejected && (!lastApproved || rejected.reviewedAt > lastApproved.reviewedAt);
  return {
    plan: pro ? 'PRO' : 'FREE',
    currentPeriodEnd: pro ? shop.proUntil.toISOString() : null,
    listingsUsed,
    pendingRequest: pending ? present(pending) : null,
    lastRejected: showRejected ? present(rejected) : null,
  };
}

// A TrxID pays for one thing only: not another subscription request, not an order's wallet payment.
async function assertTransactionUnused(tx, transactionId) {
  const [request, payment] = await Promise.all([
    tx.subscriptionRequest.findUnique({ where: { transactionId }, select: { id: true } }),
    tx.payment.findFirst({ where: { transactionId }, select: { id: true } }),
  ]);
  if (request || payment) {
    throw new AppError(409, 'This transaction ID has already been used', { code: 'TRANSACTION_USED' });
  }
}

export async function createRequest(user, shopId, input) {
  await assertOwner(user, shopId);
  if (!MERCHANT[input.method]()) throw new AppError(400, 'This payment method is not available right now');
  const amount = proPrice(input.months); // from the config, never from the client
  if (amount === undefined) throw new AppError(400, 'This subscription period is not offered');

  const request = await prisma.$transaction(async (tx) => {
    // the shop row lock makes "one pending request per shop" hold under parallel requests
    await tx.$queryRaw(Prisma.sql`SELECT id FROM "Shop" WHERE id = ${shopId} FOR UPDATE`);
    const pending = await tx.subscriptionRequest.findFirst({ where: { shopId, status: 'PENDING' }, select: { id: true } });
    if (pending) {
      throw new AppError(409, 'This shop already has a pending subscription request', { code: 'REQUEST_PENDING' });
    }
    await assertTransactionUnused(tx, input.transactionId);
    const r = await tx.subscriptionRequest.create({
      data: {
        shopId,
        plan: 'PRO',
        months: input.months,
        amount,
        method: input.method,
        walletNumber: input.walletNumber,
        transactionId: input.transactionId,
        requestedById: user.id,
      },
    });
    await audit(tx, user.id, 'subscription.requested', r.id, { shopId, months: r.months, amount, method: r.method });
    return r;
  });
  await notifySubscriptionRequested(shopId, request); // after the commit, never throws
  return present(request);
}

// Withdraw a request the admin has not reviewed yet (it is deleted).
export async function withdrawRequest(user, shopId, id) {
  await assertOwner(user, shopId);
  await prisma.$transaction(async (tx) => {
    const r = await tx.subscriptionRequest.findFirst({ where: { id, shopId }, select: { status: true } });
    if (!r) throw new AppError(404, NOT_FOUND); // another shop's request: 404
    if (r.status !== 'PENDING') throw new AppError(409, 'Only a pending request can be withdrawn');
    // the status condition loses cleanly against an admin who reviews it at the same moment
    const { count } = await tx.subscriptionRequest.deleteMany({ where: { id, status: 'PENDING' } });
    if (count === 0) throw new AppError(409, 'Only a pending request can be withdrawn');
    await audit(tx, user.id, 'subscription.withdrawn', id, { shopId });
  });
}

// ---------- admin ----------

// status optional (all). The PENDING queue is oldest request first; everything else newest first.
export async function listRequests({ status, page, limit }) {
  const where = status ? { status } : {};
  const orderBy = status === 'PENDING' ? [{ createdAt: 'asc' }, { id: 'asc' }] : [{ createdAt: 'desc' }, { id: 'asc' }];
  const [rows, total] = await prisma.$transaction([
    prisma.subscriptionRequest.findMany({ where, include: shopSelect, orderBy, skip: (page - 1) * limit, take: limit }),
    prisma.subscriptionRequest.count({ where }),
  ]);
  return { items: rows.map(presentAdmin), pagination: { page, limit, total, totalPages: Math.ceil(total / limit) } };
}

// Approve or reject a PENDING request, in one transaction. APPROVE extends Shop.proUntil by the paid
// calendar months (Asia/Dhaka), from the current end while the shop is still Pro, else from now.
export async function review(admin, id, body) {
  const approve = body.decision === 'APPROVE';
  const reviewed = await prisma.$transaction(async (tx) => {
    // the request row first (a second admin or a withdrawal waits), then the shop row
    const locked = await tx.$queryRaw(Prisma.sql`SELECT id FROM "SubscriptionRequest" WHERE id = ${id} FOR UPDATE`);
    if (locked.length === 0) throw new AppError(404, NOT_FOUND);
    const current = await tx.subscriptionRequest.findUnique({ where: { id } });
    if (current.status !== 'PENDING') throw new AppError(409, 'Only a pending request can be reviewed');

    const now = new Date();
    let period = null;
    if (approve) {
      const [shop] = await tx.$queryRaw(Prisma.sql`SELECT "proUntil" FROM "Shop" WHERE id = ${current.shopId} FOR UPDATE`);
      const proUntil = extendProUntil(shop.proUntil, current.months, now);
      await tx.shop.update({ where: { id: current.shopId }, data: { proUntil } });
      period = { from: shop.proUntil, to: proUntil };
    }
    const r = await tx.subscriptionRequest.update({
      where: { id },
      data: {
        status: approve ? 'APPROVED' : 'REJECTED',
        reviewedById: admin.id,
        reviewedAt: now,
        rejectReason: approve ? null : body.reason,
      },
      include: shopSelect,
    });
    await audit(tx, admin.id, approve ? 'subscription.approved' : 'subscription.rejected', id, {
      shopId: current.shopId,
      months: current.months,
      amount: current.amount,
      ...(approve ? { proUntil: period } : { reason: body.reason }),
    });
    return { r, proUntil: period?.to ?? null };
  });
  await notifySubscriptionReview(reviewed.r, reviewed.proUntil); // after the commit, never throws
  return presentAdmin(reviewed.r);
}
