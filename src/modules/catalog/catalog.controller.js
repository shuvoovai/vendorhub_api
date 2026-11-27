import * as catalogService from './catalog.service.js';
import { loadViewer, markViewerDependent } from '../../lib/stockVisibility.js';

export const categories = async (req, res) => {
  res.json({ success: true, data: await catalogService.listCategories(req.validated) });
};

export const brands = async (req, res) => {
  res.json({ success: true, data: await catalogService.listBrands() });
};

export const products = async (req, res) => {
  const { items, pagination, seed } = await catalogService.listProducts(req.validated);
  // a random order the server picked: the URL does not identify it, so no cache may keep it
  if (req.validated.sort === 'random' && !req.validated.seed) res.set('Cache-Control', 'private, no-store');
  res.json({ success: true, data: items, meta: { pagination, ...(seed && { seed }) } });
};

// Depends on who asks: never stored in a shared cache.
export const followingFeed = async (req, res) => {
  const { items, pagination } = await catalogService.listFollowingFeed(req.user.id, req.validated);
  res.set('Cache-Control', 'private, no-store');
  res.json({ success: true, data: items, meta: { pagination } });
};

export const product = async (req, res) => {
  const { restricted, ...data } = await catalogService.getProduct(req.params.slug, req.validated.listingId, await loadViewer(req.user));
  markViewerDependent(res, restricted);
  res.json({ success: true, data });
};

export const productListings = async (req, res) => {
  const { items, restricted } = await catalogService.getProductListings(req.params.slug, await loadViewer(req.user));
  markViewerDependent(res, restricted);
  res.json({ success: true, data: items });
};