import { Router } from 'express';
import { validate, validateQuery } from '../../middlewares/validate.js';
import { authenticate, requireRole } from '../../middlewares/auth.js';
import { subscriptionRequestLimiter } from '../../middlewares/rateLimit.js';
import { AppError } from '../../lib/errors.js';
import {
  createRequestSchema,
  adminRequestsQuery,
  reviewRequestSchema,
  shopParams,
  shopRequestParams,
  requestParams,
} from './subscriptions.schema.js';
import * as c from './subscriptions.controller.js';

const router = Router();
const adminOnly = [authenticate, requireRole('ADMIN')];

const params = (schema) => (req, res, next) =>
  schema.safeParse(req.params).success ? next() : next(new AppError(400, 'Invalid id'));

// Public (covered by the global /api/v1 rate limiter)
router.get('/subscription-plans', c.plans);

// Shop OWNER only: checked against the session user in the service (staff 403, anyone else 404)
router.get('/shops/:shopId/subscription', authenticate, params(shopParams), c.get);
router.post(
  '/shops/:shopId/subscription/requests',
  authenticate,
  subscriptionRequestLimiter,
  params(shopParams),
  validate(createRequestSchema),
  c.create,
);
router.delete('/shops/:shopId/subscription/requests/:id', authenticate, params(shopRequestParams), c.withdraw);

router.get('/admin/subscriptions/requests', ...adminOnly, validateQuery(adminRequestsQuery), c.listAll);
router.patch('/admin/subscriptions/requests/:id/review', ...adminOnly, params(requestParams), validate(reviewRequestSchema), c.review);

export default router;
