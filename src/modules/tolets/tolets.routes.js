import { Router } from 'express';
import { rateLimit, ipKeyGenerator } from 'express-rate-limit';
import { validate, validateQuery } from '../../middlewares/validate.js';
import { authenticate, optionalAuth, requireRole } from '../../middlewares/auth.js';
import { AppError } from '../../lib/errors.js';
import { createToletSchema, listToletsQuery, adminToletsQuery, reviewToletSchema, idParams,
  createInquirySchema, adminInquiriesQuery, updateInquirySchema } from './tolets.schema.js';
import * as c from './tolets.controller.js';

const router = Router();
const adminOnly = [authenticate, requireRole('ADMIN')];

// Bot brake in memory (honeypot hits count too). The real limits (3 per hour, 10 per day per IP,
// 3 pending per phone) are counted in the database by the service.
const submitLimiter = rateLimit({
  windowMs: 60 * 60 * 1000,
  limit: 20,
  skipFailedRequests: true,
  keyGenerator: (req) => `tolet:${ipKeyGenerator(req.ip)}`,
  standardHeaders: 'draft-7',
  legacyHeaders: false,
  message: { success: false, error: { message: 'Too many to-let requests from this connection. Please try again later.' } },
});

// Same idea for visit requests (the real limit, 5 saved per hour per IP, is counted in the database).
const inquiryLimiter = rateLimit({
  windowMs: 60 * 60 * 1000,
  limit: 30,
  skipFailedRequests: true,
  keyGenerator: (req) => `tolet-inquiry:${ipKeyGenerator(req.ip)}`,
  standardHeaders: 'draft-7',
  legacyHeaders: false,
  message: { success: false, error: { message: 'Too many visit requests from this connection. Please try again later.' } },
});

const validId = (req, res, next) => (idParams.safeParse(req.params).success ? next() : next(new AppError(400, 'Invalid id')));

router.get('/tolets', validateQuery(listToletsQuery), c.listPublic);
// No login needed; a valid token (if any) links the request to the account.
router.post('/tolets', optionalAuth, submitLimiter, c.honeypot, validate(createToletSchema), c.create);
router.post('/tolets/:id/inquiries', validId, inquiryLimiter, c.inquiryHoneypot, validate(createInquirySchema), c.createInquiry);

router.get('/me/tolets', authenticate, c.listMine);
router.delete('/me/tolets/:id', authenticate, validId, c.removeMine);

router.get('/admin/tolets', ...adminOnly, validateQuery(adminToletsQuery), c.adminList);
router.patch('/admin/tolets/:id', ...adminOnly, validId, validate(reviewToletSchema), c.adminReview);
router.get('/admin/tolet-inquiries', ...adminOnly, validateQuery(adminInquiriesQuery), c.adminListInquiries);
router.patch('/admin/tolet-inquiries/:id', ...adminOnly, validId, validate(updateInquirySchema), c.adminUpdateInquiry);

export default router;
