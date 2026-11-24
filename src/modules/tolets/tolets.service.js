import crypto from 'node:crypto';
import { prisma } from '../../lib/prisma.js';
import { AppError } from '../../lib/errors.js';
import { notify } from '../../lib/notify.js';
import { env } from '../../config/env.js';
import { adminIds } from '../notifications/notifications.events.js';

const APPROVAL_DAYS = 60;
const PER_HOUR = 3; // saved submissions per IP
const PER_DAY = 10;
const PENDING_PER_PHONE = 3;
const HOUR = 60 * 60 * 1000;

// A salted HMAC of the IP: enough to count submissions, useless for finding the person. The raw IP is never stored.
const ipSalt = env.IP_HASH_SALT ?? crypto.createHash('sha256').update(`tolet-ip:${env.JWT_ACCESS_SECRET}`).digest('hex');
export const hashIp = (ip) => crypto.createHmac('sha256', ipSalt).update(String(ip ?? '')).digest('hex');

const ymd = (d) => d.toISOString().slice(0, 10);

// Public answer: no submitter, IP hash, reviewer or rejection reason.
const presentPublic = (t) => ({
  id: t.id,
  type: t.type,
  title: t.title,
  marketName: t.marketName,
  floor: t.floor,
  area: t.area,
  address: t.address,
  rent: t.rent,
  advance: t.advance,
  sizeSqft: t.sizeSqft,
  availableFrom: ymd(t.availableFrom),
  description: t.description,
  status: t.status,
  createdAt: t.createdAt,
});
// The submitter's own view adds the contact and the review outcome.
const presentOwn = (t) => ({ ...presentPublic(t), contactName: t.contactName, contactPhone: t.contactPhone, rejectionReason: t.rejectionReason, expiresAt: t.expiresAt });

const visibleNow = () => ({ status: 'APPROVED', OR: [{ expiresAt: null }, { expiresAt: { gt: new Date() } }] });

export async function listPublic({ type, area, page, limit }) {
  const where = {
    ...visibleNow(),
    ...(type && { type }),
    ...(area && { area: { contains: area, mode: 'insensitive' } }),
  };
  const [total, rows] = await prisma.$transaction([
    prisma.tolet.count({ where }),
    prisma.tolet.findMany({ where, orderBy: [{ createdAt: 'desc' }, { id: 'asc' }], skip: (page - 1) * limit, take: limit }),
  ]);
  return { items: rows.map(presentPublic), pagination: { page, limit, total, totalPages: Math.ceil(total / limit) } };
}

// Spam limits, counted in the database (they survive restarts): per IP hash and per phone.
async function assertLimits(ipHash, phone) {
  const now = Date.now();
  const [lastHour, lastDay, pendingForPhone] = await Promise.all([
    prisma.tolet.count({ where: { submitterIpHash: ipHash, createdAt: { gt: new Date(now - HOUR) } } }),
    prisma.tolet.count({ where: { submitterIpHash: ipHash, createdAt: { gt: new Date(now - 24 * HOUR) } } }),
    prisma.tolet.count({ where: { contactPhone: phone, status: 'PENDING' } }),
  ]);
  if (lastHour >= PER_HOUR || lastDay >= PER_DAY) {
    throw new AppError(429, 'Too many to-let requests from this connection. Please try again later.');
  }
  if (pendingForPhone >= PENDING_PER_PHONE) {
    throw new AppError(429, 'This phone number already has several requests waiting for review.');
  }
}

export async function create(input, { userId, ip }) {
  const { website, availableFrom, ...data } = input; // website (honeypot) is handled by the route
  const ipHash = hashIp(ip);
  await assertLimits(ipHash, data.contactPhone);

  const tolet = await prisma.tolet.create({
    data: { ...data, availableFrom: new Date(`${availableFrom}T00:00:00Z`), userId: userId ?? null, submitterIpHash: ipHash },
  });
  // no phone number or name in the notification text
  await notify(await adminIds(), {
    type: 'TOLET_NEW',
    title: 'New to-let request',
    body: `${tolet.type.replace('_', ' ').toLowerCase()} in ${tolet.area}: waiting for review`,
    data: { toletId: tolet.id },
  });
  return { id: tolet.id, status: tolet.status };
}

export async function listMine(userId) {
  const rows = await prisma.tolet.findMany({ where: { userId }, orderBy: [{ createdAt: 'desc' }, { id: 'asc' }], take: 100 });
  return rows.map(presentOwn);
}

export async function removeMine(userId, id) {
  const res = await prisma.tolet.deleteMany({ where: { id, userId } });
  if (res.count !== 1) throw new AppError(404, 'To-let not found'); // someone else's: 404 too
}

// ---------- admin ----------

export async function adminList({ status, page, limit }) {
  const where = status ? { status } : {};
  const [total, rows] = await prisma.$transaction([
    prisma.tolet.count({ where }),
    prisma.tolet.findMany({
      where,
      orderBy: [{ createdAt: 'desc' }, { id: 'asc' }],
      skip: (page - 1) * limit,
      take: limit,
      include: {
        user: { select: { id: true, name: true, email: true } },
        reviewedBy: { select: { id: true, name: true } },
      },
    }),
  ]);
  return {
    items: rows.map((t) => ({ ...presentOwn(t), submitter: t.user, reviewedBy: t.reviewedBy, reviewedAt: t.reviewedAt })),
    pagination: { page, limit, total, totalPages: Math.ceil(total / limit) },
  };
}

export async function adminReview(admin, id, { status, reason }) {
  const updated = await prisma.$transaction(async (tx) => {
    const t = await tx.tolet.findUnique({ where: { id } });
    if (!t) throw new AppError(404, 'To-let not found');
    if (t.status === status) throw new AppError(409, `This request is already ${status.toLowerCase()}`);
    const approved = status === 'APPROVED';
    const u = await tx.tolet.update({
      where: { id },
      data: {
        status,
        rejectionReason: approved ? null : reason,
        expiresAt: approved ? new Date(Date.now() + APPROVAL_DAYS * 24 * HOUR) : null,
        reviewedById: admin.id,
        reviewedAt: new Date(),
      },
    });
    await tx.auditLog.create({
      data: {
        actorId: admin.id,
        action: approved ? 'tolet.approved' : 'tolet.rejected',
        entityType: 'Tolet',
        entityId: id,
        meta: { from: t.status, to: status, ...(reason && { reason }) },
      },
    });
    return u;
  });

  if (updated.userId) {
    await notify([updated.userId], {
      type: 'TOLET_REVIEWED',
      title: updated.status === 'APPROVED' ? 'Your to-let is live' : 'Your to-let was not approved',
      body: updated.status === 'APPROVED' ? `"${updated.title}" is now listed for ${APPROVAL_DAYS} days.` : `"${updated.title}": ${updated.rejectionReason}`,
      data: { toletId: updated.id, status: updated.status },
    });
  }
  return presentOwn(updated);
}

// ---------- inquiries (visit requests) ----------

const INQUIRY_PER_HOUR = 5; // saved inquiries per IP
// Allowed status changes; anything else is 409.
const INQUIRY_MOVES = { NEW: ['CONTACTED', 'CLOSED'], CONTACTED: ['CLOSED'], CLOSED: ['NEW'] };

export async function createInquiry(toletId, input, { ip }) {
  const { website, preferredDate, ...data } = input; // website (honeypot) is handled by the route
  const tolet = await prisma.tolet.findFirst({ where: { id: toletId, ...visibleNow() }, select: { id: true } });
  if (!tolet) throw new AppError(404, 'To-let not found');

  const ipHash = hashIp(ip);
  const lastHour = await prisma.toletInquiry.count({ where: { submitterIpHash: ipHash, createdAt: { gt: new Date(Date.now() - HOUR) } } });
  if (lastHour >= INQUIRY_PER_HOUR) throw new AppError(429, 'Too many visit requests from this connection. Please try again later.');

  const row = await prisma.toletInquiry.create({
    data: { ...data, toletId, preferredDate: new Date(`${preferredDate}T00:00:00Z`), submitterIpHash: ipHash },
    select: { id: true },
  });
  return { id: row.id };
}

const presentInquiry = (q) => ({
  id: q.id,
  name: q.name,
  phone: q.phone,
  preferredDate: ymd(q.preferredDate),
  preferredTime: q.preferredTime,
  message: q.message,
  status: q.status,
  createdAt: q.createdAt,
  tolet: q.tolet,
});

const inquiryToletSelect = {
  select: { id: true, title: true, type: true, area: true, marketName: true, rent: true, contactName: true, contactPhone: true },
};

export async function adminListInquiries({ status }) {
  const rows = await prisma.toletInquiry.findMany({
    where: status ? { status } : {},
    orderBy: [{ createdAt: 'desc' }, { id: 'asc' }],
    take: 100,
    include: { tolet: inquiryToletSelect },
  });
  return rows.map(presentInquiry);
}

export async function adminUpdateInquiry(admin, id, { status }) {
  const updated = await prisma.$transaction(async (tx) => {
    const q = await tx.toletInquiry.findUnique({ where: { id }, select: { status: true } });
    if (!q) throw new AppError(404, 'Inquiry not found');
    if (!INQUIRY_MOVES[q.status].includes(status)) throw new AppError(409, 'This status change is not allowed');
    // guarded update: a parallel change in between makes count 0 -> 409
    const res = await tx.toletInquiry.updateMany({ where: { id, status: q.status }, data: { status } });
    if (res.count !== 1) throw new AppError(409, 'This status change is not allowed');
    await tx.auditLog.create({
      data: { actorId: admin.id, action: 'tolet_inquiry.status', entityType: 'ToletInquiry', entityId: id, meta: { from: q.status, to: status } },
    });
    return tx.toletInquiry.findUnique({ where: { id }, include: { tolet: inquiryToletSelect } });
  });
  return presentInquiry(updated);
}
