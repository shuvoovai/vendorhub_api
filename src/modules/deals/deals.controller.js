import * as s from './deals.service.js';

const ok = (res, data) => res.json({ success: true, data });

// Public: short cache; a deal that ends drops out within a minute.
export const listFlash = async (req, res) => {
  res.set('Cache-Control', 'public, max-age=60');
  ok(res, await s.listFlash(req.validated));
};

export const listForShop = async (req, res) => ok(res, await s.listForShop(req.user, req.params.shopId));
export const create = async (req, res) =>
  res.status(201).json({ success: true, data: await s.create(req.user, req.params.shopId, req.body) });
export const update = async (req, res) => ok(res, await s.update(req.user, req.params.shopId, req.params.id, req.body));
export const remove = async (req, res) => {
  await s.remove(req.user, req.params.shopId, req.params.id);
  ok(res, { message: 'Deal deleted' });
};

export const listAll = async (req, res) => {
  const { items, pagination } = await s.listAll(req.validated);
  res.json({ success: true, data: items, meta: { pagination } });
};
export const adminRemove = async (req, res) => {
  await s.adminRemove(req.user, req.params.id);
  ok(res, { message: 'Deal deleted' });
};
