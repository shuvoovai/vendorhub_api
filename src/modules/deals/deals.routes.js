import { Router } from 'express';
import { validate, validateQuery } from '../../middlewares/validate.js';
import { authenticate, requireRole } from '../../middlewares/auth.js';
import { AppError } from '../../lib/errors.js';
import {
  createDealSchema,
  updateDealSchema,
  flashQuery,
  adminDealsQuery,
  shopParams,
  shopDealParams,
  dealParams,
} from './deals.schema.js';
import * as c from './deals.controller.js';

const router = Router();
const shopTeam = [authenticate, requireRole('SHOP_OWNER', 'SHOP_STAFF', 'ADMIN')];
const adminOnly = [authenticate, requireRole('ADMIN')];

const params = (schema) => (req, res, next) =>
  schema.safeParse(req.params).success ? next() : next(new AppError(400, 'Invalid id'));

// Public (covered by the global /api/v1 rate limiter)
router.get('/deals/flash', validateQuery(flashQuery), c.listFlash);

// Shop team: only deals on the shop's own listings (assertShopAccess in the service)
router.get('/owner/shops/:shopId/deals', ...shopTeam, params(shopParams), c.listForShop);
router.post('/owner/shops/:shopId/deals', ...shopTeam, params(shopParams), validate(createDealSchema), c.create);
router.patch('/owner/shops/:shopId/deals/:id', ...shopTeam, params(shopDealParams), validate(updateDealSchema), c.update);
router.delete('/owner/shops/:shopId/deals/:id', ...shopTeam, params(shopDealParams), c.remove);

router.get('/admin/deals', ...adminOnly, validateQuery(adminDealsQuery), c.listAll);
router.delete('/admin/deals/:id', ...adminOnly, params(dealParams), c.adminRemove);

export default router;
