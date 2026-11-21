import { Router } from 'express';
import { validateQuery } from '../../middlewares/validate.js';
import { listProductsQuery, productDetailQuery, categoriesQuery } from './catalog.schema.js';
import * as controller from './catalog.controller.js';

const router = Router();

router.get('/categories', validateQuery(categoriesQuery), controller.categories);
router.get('/brands', controller.brands);
router.get('/products', validateQuery(listProductsQuery), controller.products);
router.get('/products/:slug', validateQuery(productDetailQuery), controller.product);
router.get('/products/:slug/listings', controller.productListings);
export default router;