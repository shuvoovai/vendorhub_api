import * as s from './banners.service.js';

const ok = (res, data) => res.json({ success: true, data });

// Public: short cache, so admin changes show up within a minute.
export const listPublic = async (req, res) => {
  res.set('Cache-Control', 'public, max-age=60');
  ok(res, await s.listPublic());
};

export const listAll = async (req, res) => ok(res, await s.listAll());
export const create = async (req, res) =>
  res.status(201).json({ success: true, data: await s.create(req.user, req.body, req.file, req.video) });
export const update = async (req, res) => ok(res, await s.update(req.user, req.params.id, req.body, req.file, req.video));
export const reorder = async (req, res) => ok(res, await s.reorder(req.user, req.body.ids));
export const remove = async (req, res) => {
  await s.remove(req.user, req.params.id);
  ok(res, { message: 'Banner deleted' });
};
