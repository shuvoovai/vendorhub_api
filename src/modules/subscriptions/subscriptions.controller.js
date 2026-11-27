import * as s from './subscriptions.service.js';

const ok = (res, data) => res.json({ success: true, data });

// Public: the plans change only with a deploy (src/config/plans.js).
export const plans = (req, res) => {
  res.set('Cache-Control', 'public, max-age=300');
  ok(res, s.listPlans());
};

export const get = async (req, res) => ok(res, await s.getSubscription(req.user, req.params.shopId));
export const create = async (req, res) =>
  res.status(201).json({ success: true, data: await s.createRequest(req.user, req.params.shopId, req.body) });
export const withdraw = async (req, res) => {
  await s.withdrawRequest(req.user, req.params.shopId, req.params.id);
  res.status(204).end();
};

export const listAll = async (req, res) => {
  const { items, pagination } = await s.listRequests(req.validated);
  res.json({ success: true, data: items, meta: { pagination } });
};
export const review = async (req, res) => ok(res, await s.review(req.user, req.params.id, req.body));
