// Who may see a listing's stock NUMBER. Availability (IN_STOCK, LIMITED, ...) is always public;
// the number is sent only when the listing's stockVisibility allows it for this viewer, else null.
//   PUBLIC  -> everyone
//   VENDORS -> ADMIN, or owner/staff of any VERIFIED (and active) shop
//   HIDDEN  -> ADMIN, or owner/staff of this listing's shop
// Every public response that carries a listing's stockQty goes through visibleStockQty().
import { prisma } from './prisma.js';

/**
 * Who is looking. null for a guest. Loads the user's shop memberships once (call once per request).
 * @param {{ id: string, role?: string } | null | undefined} user
 */
export async function loadViewer(user) {
  if (!user?.id) return null;
  const role = user.role ?? (await prisma.user.findUnique({ where: { id: user.id }, select: { role: true } }))?.role;
  if (role === 'ADMIN') return { id: user.id, isAdmin: true, teamShopIds: new Set(), verifiedVendor: true };

  const shops = await prisma.shop.findMany({
    where: { OR: [{ ownerId: user.id }, { staff: { some: { userId: user.id } } }] },
    select: { id: true, isActive: true, verificationLevel: true },
  });
  return {
    id: user.id,
    isAdmin: false,
    teamShopIds: new Set(shops.map((s) => s.id)),
    verifiedVendor: shops.some((s) => s.isActive && s.verificationLevel !== 'UNVERIFIED'),
  };
}

/** @param listing { shopId, stockVisibility } */
export function canSeeStockQty(viewer, listing) {
  switch (listing.stockVisibility) {
    case 'PUBLIC':
      return true;
    case 'VENDORS':
      return Boolean(viewer && (viewer.isAdmin || viewer.verifiedVendor || viewer.teamShopIds.has(listing.shopId)));
    default: // HIDDEN, and any unknown value: the safe answer
      return Boolean(viewer && (viewer.isAdmin || viewer.teamShopIds.has(listing.shopId)));
  }
}

/** The stockQty to send to this viewer: the number, or null. */
export const visibleStockQty = (viewer, listing) =>
  listing.stockQty !== null && listing.stockQty !== undefined && canSeeStockQty(viewer, listing) ? listing.stockQty : null;

/**
 * A response that contains a counted, non-PUBLIC listing depends on who asks: it must never be
 * stored in a shared cache. (Guests always get null for those, so a guest answer is safe anyway.)
 */
export function markViewerDependent(res, listings) {
  const restricted = listings.some((l) => l.stockQty !== null && l.stockQty !== undefined && l.stockVisibility !== 'PUBLIC');
  if (restricted) {
    res.set('Cache-Control', 'private, no-store');
    res.vary('Authorization');
  }
}
