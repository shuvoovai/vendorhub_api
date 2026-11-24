import { env } from '../../config/env.js';
import * as cartService from './cart.service.js';

// Guest cart cookie: a random UUID, invisible to JavaScript, only sent to the cart endpoints.
export const GUEST_COOKIE = 'vh_guest_cart';
const guestCookieOptions = () => ({
  httpOnly: true,
  sameSite: 'lax',
  secure: env.COOKIE_SECURE ?? env.NODE_ENV === 'production',
  path: '/api/v1/cart',
  maxAge: cartService.GUEST_CART_DAYS * 24 * 60 * 60 * 1000,
});
const clearGuestCookie = (res) => {
  const { maxAge, ...opts } = guestCookieOptions();
  res.clearCookie(GUEST_COOKIE, opts);
};

const send = (res, data) => {
  res.set('Cache-Control', 'private, no-store');
  res.json({ success: true, data });
};

// The cart owner: the logged-in user, or the guest cart named by the cookie (never by the body, query or a header).
// null: a guest without a (known) cart.
async function ownerOf(req) {
  if (req.user) return { userId: req.user.id };
  return cartService.findGuestCart(req.cookies?.[GUEST_COOKIE]);
}

export const get = async (req, res) => send(res, await cartService.getCart(await ownerOf(req)));

export const addItem = async (req, res) => {
  let owner = await ownerOf(req);
  if (!owner) {
    await cartService.checkListing(req.body.listingId, req.body.variantId); // no empty guest cart for an invalid add
    const created = await cartService.createGuestCart();
    owner = created.owner;
    res.cookie(GUEST_COOKIE, created.token, guestCookieOptions());
  }
  send(res, await cartService.addItem(owner, req.body));
};

export const updateItem = async (req, res) =>
  send(res, await cartService.updateItem(await ownerOf(req), req.params.itemId, req.body));

export const removeItem = async (req, res) => send(res, await cartService.removeItem(await ownerOf(req), req.params.itemId));

export const clear = async (req, res) => send(res, await cartService.clearCart(await ownerOf(req)));

// POST /cart/merge (login required): the guest cart named by the cookie goes into the user's cart.
export const merge = async (req, res) => {
  const guest = await cartService.findGuestCart(req.cookies?.[GUEST_COOKIE]);
  await cartService.mergeGuestCart(req.user.id, guest);
  if (req.cookies?.[GUEST_COOKIE] !== undefined) clearGuestCookie(res);
  send(res, await cartService.getCart({ userId: req.user.id }));
};
