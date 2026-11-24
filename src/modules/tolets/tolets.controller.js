import crypto from 'node:crypto';
import * as s from './tolets.service.js';

const ok = (res, data) => res.json({ success: true, data });

export const listPublic = async (req, res) => {
  const { items, pagination } = await s.listPublic(req.validated);
  res.set('Cache-Control', 'public, max-age=60'); // approved listings only; changes show within a minute
  res.json({ success: true, data: items, meta: { pagination } });
};

// Honeypot: a filled "website" field means a bot. It gets the same answer as a real submission
// (so it cannot tell), but nothing is saved, nobody is notified, and the body is not validated further.
export const honeypot = (req, res, next) => {
  const trap = req.body?.website;
  if (typeof trap === 'string' && trap.trim() !== '') {
    return res.status(201).json({ success: true, data: { id: crypto.randomUUID(), status: 'PENDING' } });
  }
  next();
};

export const create = async (req, res) =>
  res.status(201).json({ success: true, data: await s.create(req.body, { userId: req.user?.id, ip: req.ip }) });

export const listMine = async (req, res) => {
  res.set('Cache-Control', 'private, no-store');
  ok(res, await s.listMine(req.user.id));
};
export const removeMine = async (req, res) => {
  await s.removeMine(req.user.id, req.params.id);
  ok(res, { message: 'To-let deleted' });
};

export const adminList = async (req, res) => {
  const { items, pagination } = await s.adminList(req.validated);
  res.json({ success: true, data: items, meta: { pagination } });
};
export const adminReview = async (req, res) => ok(res, await s.adminReview(req.user, req.params.id, req.body));

// Inquiry honeypot: same 201 shape as a real one, nothing saved.
export const inquiryHoneypot = (req, res, next) => {
  const trap = req.body?.website;
  if (typeof trap === 'string' && trap.trim() !== '') {
    return res.status(201).json({ success: true, data: { id: crypto.randomUUID() } });
  }
  next();
};
export const createInquiry = async (req, res) =>
  res.status(201).json({ success: true, data: await s.createInquiry(req.params.id, req.body, { ip: req.ip }) });

export const adminListInquiries = async (req, res) => {
  res.set('Cache-Control', 'private, no-store');
  ok(res, await s.adminListInquiries(req.validated));
};
export const adminUpdateInquiry = async (req, res) => ok(res, await s.adminUpdateInquiry(req.user, req.params.id, req.body));
