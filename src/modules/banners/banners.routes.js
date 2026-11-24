import { Router } from 'express';
import { validate } from '../../middlewares/validate.js';
import { authenticate, requireRole } from '../../middlewares/auth.js';
import { uploadLimiter } from '../../middlewares/rateLimit.js';
import { receiveBannerForm } from '../../middlewares/photoUpload.js';
import { AppError } from '../../lib/errors.js';
import { createBannerSchema, updateBannerSchema, reorderSchema, idParams } from './banners.schema.js';
import * as c from './banners.controller.js';

const router = Router();
const adminOnly = [authenticate, requireRole('ADMIN')];

const validId = (req, res, next) => {
  if (!idParams.safeParse(req.params).success) return next(new AppError(400, 'Invalid id'));
  next();
};
// multer leaves req.body undefined when no field was sent
const body = (req, res, next) => {
  req.body ??= {};
  next();
};

// Upload quota only for multipart requests: a JSON PATCH (e.g. show/hide) carries no file.
const uploadQuota = (req, res, next) => (req.is('multipart/form-data') ? uploadLimiter(req, res, next) : next());

// Public (covered by the global /api/v1 rate limiter)
router.get('/banners', c.listPublic);

router.get('/admin/banners', ...adminOnly, c.listAll);
router.post('/admin/banners', ...adminOnly, uploadLimiter, receiveBannerForm, body, validate(createBannerSchema), c.create);
// before /:id so "reorder" is never read as an id
router.patch('/admin/banners/reorder', ...adminOnly, validate(reorderSchema), c.reorder);
router.patch('/admin/banners/:id', ...adminOnly, validId, uploadQuota, receiveBannerForm, body, validate(updateBannerSchema), c.update);
router.delete('/admin/banners/:id', ...adminOnly, validId, c.remove);

export default router;
