import { Router } from 'express';
import { rateLimit } from 'express-rate-limit';
import { validate, validateQuery } from '../../middlewares/validate.js';
import { authenticate, requireRole } from '../../middlewares/auth.js';
import { AppError } from '../../lib/errors.js';
import {
  createFoodOrderSchema,
  adminFoodOrdersQuery,
  foodOrderStatusSchema,
  createFoodItemSchema,
  updateFoodItemSchema,
  idParams,
} from './food.schema.js';
import * as c from './food.controller.js';

const router = Router();
// Food corner: vendors only (customers and guests get 403); admins manage it.
const vendors = [authenticate, requireRole('SHOP_OWNER', 'SHOP_STAFF', 'ADMIN')];
const vendorsOnly = [authenticate, requireRole('SHOP_OWNER', 'SHOP_STAFF')];
const adminOnly = [authenticate, requireRole('ADMIN')];

// About 10 accepted orders per hour per user. Always on; rejected requests do not count.
const orderLimiter = rateLimit({
  windowMs: 60 * 60 * 1000,
  limit: 10,
  skipFailedRequests: true,
  keyGenerator: (req) => `food-order:${req.user.id}`,
  standardHeaders: 'draft-7',
  legacyHeaders: false,
  message: { success: false, error: { message: 'Too many food orders. Please try again later.' } },
});

const validId = (req, res, next) => (idParams.safeParse(req.params).success ? next() : next(new AppError(400, 'Invalid id')));

router.get('/food/items', ...vendors, c.listItems);
router.post('/food/orders', ...vendorsOnly, orderLimiter, validate(createFoodOrderSchema), c.createOrder);
router.get('/me/food-orders', ...vendorsOnly, c.listMyOrders);

router.get('/admin/food-orders', ...adminOnly, validateQuery(adminFoodOrdersQuery), c.adminListOrders);
router.patch('/admin/food-orders/:id', ...adminOnly, validId, validate(foodOrderStatusSchema), c.adminSetStatus);

router.get('/admin/food-items', ...adminOnly, c.adminListItems);
router.post('/admin/food-items', ...adminOnly, validate(createFoodItemSchema), c.adminCreateItem);
router.patch('/admin/food-items/:id', ...adminOnly, validId, validate(updateFoodItemSchema), c.adminUpdateItem);
router.delete('/admin/food-items/:id', ...adminOnly, validId, c.adminDeleteItem);

export default router;
