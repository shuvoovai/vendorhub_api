import { prisma } from '../../lib/prisma.js';
import { AppError } from '../../lib/errors.js';
import { orderInclude, formatOrder } from '../checkout/checkout.service.js';
import { cancelEffects } from '../fulfilment/fulfilment.service.js';
import { notifyAdminOrderChange } from '../notifications/notifications.events.js';

// Admins see an order only after the shop has accepted it.
const visible = { status: { not: 'PLACED' } };

const include = {
  ...orderInclude,
  checkout: { select: { user: { select: { id: true, name: true, phone: true } } } },
  // ADMIN ONLY: the wallet + TrxID let the admin find the bKash / Nagad money in the merchant account.
  // Never in customer or shop answers, never logged.
  payments: {
    select: { id: true, provider: true, amount: true, status: true, walletNumber: true, transactionId: true, createdAt: true },
    orderBy: { createdAt: 'asc' },
  },
};

const format = (o) => ({
  ...formatOrder(o),
  customer: o.checkout.user,
  payments: o.payments.map((p) => ({
    id: p.id,
    provider: p.provider,
    amount: p.amount,
    status: p.status,
    walletNumber: p.walletNumber ?? null,
    transactionId: p.transactionId ?? null,
    createdAt: p.createdAt,
  })),
});

const FINAL = ['COMPLETED', 'CANCELLED'];

function checkStatus(order, next) {
  const ok =
    (next === 'READY_FOR_PICKUP' && order.status === 'CONFIRMED' && order.deliveryMethod === 'STORE_PICKUP') ||
    (next === 'OUT_FOR_DELIVERY' && order.status === 'CONFIRMED' && order.deliveryMethod === 'VENDOR_DELIVERY') ||
    (next === 'COMPLETED' && ['READY_FOR_PICKUP', 'OUT_FOR_DELIVERY'].includes(order.status)) ||
    (next === 'CANCELLED' && !FINAL.includes(order.status));
  if (!ok) throw new AppError(409, `An order that is ${order.status} cannot move to ${next}`);
}

// statusAfter: the order status once this request is applied
function checkPayment(order, next, statusAfter) {
  const from = order.paymentStatus;
  const ok =
    (next === 'PAID' && ['PENDING', 'FAILED'].includes(from) && statusAfter !== 'CANCELLED') ||
    (next === 'REFUNDED' && from === 'PAID' && statusAfter === 'CANCELLED');
  if (!ok) throw new AppError(409, `A payment that is ${from} cannot move to ${next} for this order`);
}

export async function listOrders({ status, page, limit }) {
  const where = status ? { AND: [visible, { status }] } : visible;
  const [total, rows] = await Promise.all([
    prisma.subOrder.count({ where }),
    prisma.subOrder.findMany({
      where,
      include,
      orderBy: { createdAt: 'desc' },
      skip: (page - 1) * limit,
      take: limit,
    }),
  ]);
  return {
    items: rows.map(format),
    pagination: { page, limit, total, totalPages: Math.ceil(total / limit) },
  };
}

async function getOrder(orderId) {
  const order = await prisma.subOrder.findFirst({ where: { id: orderId, ...visible }, include });
  if (!order) throw new AppError(404, 'Order not found');
  return order;
}

export async function updateOrder(admin, orderId, { status, paymentStatus }) {
  const order = await getOrder(orderId);
  if (status) checkStatus(order, status);
  const statusAfter = status ?? order.status;
  if (paymentStatus) checkPayment(order, paymentStatus, statusAfter);

  await prisma.$transaction(async (tx) => {
    // the status/payment condition makes a concurrent change fail instead of being overwritten.
    // paymentStatus is written here too: a payment-only change must not send an empty update (count 0).
    const changed = await tx.subOrder.updateMany({
      where: { id: orderId, status: order.status, paymentStatus: order.paymentStatus },
      data: {
        ...(status && { status }),
        ...(status === 'COMPLETED' && { completedAt: new Date() }),
        ...(paymentStatus && { paymentStatus }),
      },
    });
    if (changed.count !== 1) throw new AppError(409, 'This order just changed. Refresh and try again.');

    if (status === 'CANCELLED') await cancelEffects(tx, order); // restock (+ auto refund for ONLINE)

    if (paymentStatus) {
      const moved = await tx.payment.updateMany({
        where: { subOrderId: orderId, status: paymentStatus === 'PAID' ? { in: ['PENDING', 'FAILED'] } : 'PAID' },
        data: { status: paymentStatus },
      });
      if (paymentStatus === 'PAID' && moved.count === 0) {
        // cash orders have no payment row: record the manual confirmation
        await tx.payment.create({
          data: { subOrderId: orderId, provider: 'manual', amount: order.total, status: 'PAID' },
        });
      }
    }

    await tx.auditLog.create({
      data: {
        actorId: admin.id,
        action: 'order.admin_updated',
        entityType: 'SubOrder',
        entityId: orderId,
        meta: {
          ...(status && { status: { from: order.status, to: status } }),
          ...(paymentStatus && { paymentStatus: { from: order.paymentStatus, to: paymentStatus } }),
        },
      },
    });
  });

  await notifyAdminOrderChange(order, { status, paymentStatus }); // after the commit, never throws
  return format(await getOrder(orderId));
}
