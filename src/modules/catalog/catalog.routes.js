import { Router } from 'express';
import { validateQuery } from '../../middlewares/validate.js';
import { authenticate, optionalAuth } from '../../middlewares/auth.js';
import { listProductsQuery, productDetailQuery, categoriesQuery, followingFeedQuery } from './catalog.schema.js';
import * as controller from './catalog.controller.js';

const router = Router();

router.get('/categories', validateQuery(categoriesQuery), controller.categories);
router.get('/brands', controller.brands);
router.get('/products', validateQuery(listProductsQuery), controller.products);
// before /products/:slug, so "following" is never read as a product slug
router.get('/products/following', authenticate, validateQuery(followingFeedQuery), controller.followingFeed);
router.get('/products/:slug', optionalAuth, validateQuery(productDetailQuery), controller.product);
router.get('/products/:slug/listings', optionalAuth, controller.productListings);
export default router;