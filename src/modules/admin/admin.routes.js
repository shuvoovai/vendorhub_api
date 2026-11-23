import { Router } from 'express';
import { validate, validateQuery } from '../../middlewares/validate.js';
import { authenticate, requireRole } from '../../middlewares/auth.js';
import { listShopsQuery, shopStatusSchema, salesQuery, topQuery, listOrdersQuery, updateOrderSchema } from './admin.schema.js';
import * as c from './admin.controller.js';

const router = Router();
const adminOnly = [authenticate, requireRole('ADMIN')];

// authenticate is applied per route because this router is mounted at /api/v1
router.get('/admin/shops', ...adminOnly, validateQuery(listShopsQuery), c.listShops);
router.patch('/admin/shops/:shopId/status', ...adminOnly, validate(shopStatusSchema), c.setShopStatus);
router.get('/admin/reports/sales', ...adminOnly, validateQuery(salesQuery), c.sales);
router.get('/admin/reports/top', ...adminOnly, validateQuery(topQuery), c.top);
router.get('/admin/orders', ...adminOnly, validateQuery(listOrdersQuery), c.listOrders);
router.patch('/admin/orders/:orderId', ...adminOnly, validate(updateOrderSchema), c.updateOrder);

export default router;