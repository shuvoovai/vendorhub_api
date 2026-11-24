import { Router } from 'express';
import { rateLimit, ipKeyGenerator } from 'express-rate-limit';
import { validate } from '../../middlewares/validate.js';
import { authenticate } from '../../middlewares/auth.js';
import { AppError } from '../../lib/errors.js';
import { addItemSchema, updateItemSchema, itemParams } from './cart.schema.js';
import * as c from './cart.controller.js';

const router = Router();

// Logged in OR guest. A Bearer token, when sent, must be valid (401 otherwise, so the website refreshes it
// instead of silently switching to a guest cart) and gets the usual account checks.
const userOrGuest = (req, res, next) => (req.headers.authorization ? authenticate(req, res, next) : next());

// Guest cart writes, per IP (logged-in users are not counted here). Always on.
const guestWriteLimiter = rateLimit({
  windowMs: 60 * 1000,
  limit: 60,
  skip: (req) => Boolean(req.user),
  keyGenerator: (req) => `guest-cart:${ipKeyGenerator(req.ip)}`,
  standardHeaders: 'draft-7',
  legacyHeaders: false,
  message: { success: false, error: { message: 'Too many cart changes from this connection. Please try again later.' } },
});

const validItemId = (req, res, next) => (itemParams.safeParse(req.params).success ? next() : next(new AppError(404, 'Cart item not found')));

router.post('/merge', authenticate, c.merge);

router.use(userOrGuest);
router.get('/', c.get);
router.post('/items', guestWriteLimiter, validate(addItemSchema), c.addItem);
router.patch('/items/:itemId', guestWriteLimiter, validItemId, validate(updateItemSchema), c.updateItem);
router.delete('/items/:itemId', guestWriteLimiter, validItemId, c.removeItem);
router.delete('/', guestWriteLimiter, c.clear);

export default router;
