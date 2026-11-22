import * as s from './food.service.js';

const ok = (res, data) => res.json({ success: true, data });
const created = (res, data) => res.status(201).json({ success: true, data });
const privateAnswer = (res) => res.set('Cache-Control', 'private, no-store');

export const listItems = async (req, res) => {
  privateAnswer(res); // vendors only: never in a shared cache
  ok(res, await s.listItems());
};
export const createOrder = async (req, res) => created(res, await s.createOrder(req.user, req.body));
export const listMyOrders = async (req, res) => {
  privateAnswer(res);
  ok(res, await s.listMyOrders(req.user.id));
};

export const adminListOrders = async (req, res) => {
  const { items, pagination } = await s.adminListOrders(req.validated);
  res.json({ success: true, data: items, meta: { pagination } });
};
export const adminSetStatus = async (req, res) => ok(res, await s.adminSetStatus(req.user, req.params.id, req.body.status));

export const adminListItems = async (req, res) => ok(res, await s.adminListItems());
export const adminCreateItem = async (req, res) => created(res, await s.adminCreateItem(req.user, req.body));
export const adminUpdateItem = async (req, res) => ok(res, await s.adminUpdateItem(req.user, req.params.id, req.body));
export const adminDeleteItem = async (req, res) => {
  await s.adminDeleteItem(req.user, req.params.id);
  ok(res, { message: 'Food item deleted' });
};
