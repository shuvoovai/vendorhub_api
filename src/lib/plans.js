// A shop's effective plan and the limits it enforces. The plan is computed on read (no cron job):
// PRO while Shop.proUntil > now, else FREE. Prices and limits: src/config/plans.js.
import { Prisma } from '@prisma/client';
import { PLANS } from '../config/plans.js';
import { AppError } from './errors.js';

export const isPro = (proUntil, now = new Date()) => Boolean(proUntil) && new Date(proUntil) > now;
export const planOf = (proUntil, now = new Date()) => (isPro(proUntil, now) ? PLANS.PRO : PLANS.FREE);

// Bangladesh time has no daylight saving: always UTC+6.
const DHAKA_OFFSET_MS = 6 * 60 * 60 * 1000;

/**
 * Adds calendar months in Asia/Dhaka time. The day is clamped to the end of a shorter month
 * (31 Jan + 1 month = 28/29 Feb), the time of day stays the same.
 */
export function addMonthsDhaka(date, months) {
  const local = new Date(date.getTime() + DHAKA_OFFSET_MS); // UTC fields of `local` = Dhaka wall clock
  const day = local.getUTCDate();
  local.setUTCDate(1);
  local.setUTCMonth(local.getUTCMonth() + months);
  const lastDay = new Date(Date.UTC(local.getUTCFullYear(), local.getUTCMonth() + 1, 0)).getUTCDate();
  local.setUTCDate(Math.min(day, lastDay));
  return new Date(local.getTime() - DHAKA_OFFSET_MS);
}

/** New proUntil after paying for `months`: from now, or from the current end while still Pro. */
export const extendProUntil = (proUntil, months, now = new Date()) =>
  addMonthsDhaka(isPro(proUntil, now) ? new Date(proUntil) : now, months);

/**
 * Call inside a transaction BEFORE a listing becomes active (new, re-activated, or a shop's own new product).
 * Locks the shop row so two parallel requests cannot both pass the count. FREE shops at the limit: 403.
 */
export async function assertCanAddListing(tx, shopId) {
  const rows = await tx.$queryRaw(Prisma.sql`SELECT "proUntil" FROM "Shop" WHERE id = ${shopId} FOR UPDATE`);
  if (rows.length === 0) throw new AppError(404, 'Shop not found');
  const { maxListings } = planOf(rows[0].proUntil);
  if (maxListings === null) return;
  const active = await tx.shopListing.count({ where: { shopId, isActive: true } });
  if (active >= maxListings) {
    throw new AppError(403, 'Your plan allows no more active listings. Upgrade to Pro to add more.', {
      code: 'PLAN_LIMIT',
      maxListings,
    });
  }
}

/** Flash deal requests need a plan with flashDeals (Pro). Deals approved earlier keep running. */
export async function assertCanRequestDeals(db, shopId) {
  const shop = await db.shop.findUnique({ where: { id: shopId }, select: { proUntil: true } });
  if (!shop) throw new AppError(404, 'Shop not found');
  if (!planOf(shop.proUntil).flashDeals) {
    throw new AppError(403, 'Flash deals are part of the Pro plan', { code: 'PLAN_REQUIRED', plan: 'PRO' });
  }
}
