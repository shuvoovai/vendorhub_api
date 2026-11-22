import { prisma } from '../../lib/prisma.js';
import { AppError } from '../../lib/errors.js';
import { notify } from '../../lib/notify.js';
import { adminIds } from '../notifications/notifications.events.js';

const ITEM_SELECT = {
  id: true,
  nameEn: true,
  nameBn: true,
  descriptionEn: true,
  descriptionBn: true,
  price: true,
  emoji: true,
  isAvailable: true,
};

// Allowed status changes; anything else is 409.
const NEXT = {
  PENDING: ['CONFIRMED', 'CANCELLED'],
  CONFIRMED: ['DELIVERED', 'CANCELLED'],
  DELIVERED: [],
  CANCELLED: [],
};

const presentOrder = (o) => ({
  id: o.id,
  itemId: o.itemId,
  itemName: o.itemName,
  unitPrice: o.unitPrice,
  quantity: o.quantity,
  total: o.total,
  name: o.name,
  phone: o.phone,
  address: o.address,
  note: o.note,
  status: o.status,
  createdAt: o.createdAt,
  updatedAt: o.updatedAt,
});

const audit = (db, actorId, action, entityType, entityId, meta) =>
  db.auditLog.create({ data: { actorId, action, entityType, entityId, meta } });

// ---------- vendors ----------

export async function listItems() {
  return prisma.foodItem.findMany({
    where: { isAvailable: true },
    orderBy: [{ sortOrder: 'asc' }, { nameEn: 'asc' }],
    select: ITEM_SELECT,
  });
}

// The vendor's shop: the one they own, else the one they work in (oldest first). null for an admin.
async function vendorShopId(userId) {
  const owned = await prisma.shop.findFirst({ where: { ownerId: userId }, orderBy: { createdAt: 'asc' }, select: { id: true } });
  if (owned) return owned.id;
  const staff = await prisma.shopStaff.findFirst({ where: { userId }, select: { shopId: true } });
  return staff?.shopId ?? null;
}

export async function createOrder(user, input) {
  const item = await prisma.foodItem.findUnique({ where: { id: input.itemId } });
  if (!item) throw new AppError(404, 'Food item not found');
  if (!item.isAvailable) throw new AppError(409, 'This item is not available right now');

  // the price always comes from the menu, never from the client
  const order = await prisma.foodOrder.create({
    data: {
      userId: user.id,
      shopId: await vendorShopId(user.id),
      itemId: item.id,
      itemName: item.nameEn,
      unitPrice: item.price,
      quantity: input.quantity,
      total: item.price * input.quantity,
      name: input.name,
      phone: input.phone,
      address: input.address,
      note: input.note ?? null,
    },
  });

  await notify(await adminIds(), {
    type: 'FOOD_ORDER_NEW',
    title: 'New food order',
    body: `${order.quantity} x ${order.itemName} (${order.total} BDT)`,
    data: { foodOrderId: order.id },
  });
  return presentOrder(order);
}

export async function listMyOrders(userId) {
  const rows = await prisma.foodOrder.findMany({ where: { userId }, orderBy: [{ createdAt: 'desc' }, { id: 'asc' }], take: 100 });
  return rows.map(presentOrder);
}

// ---------- admin: orders ----------

export async function adminListOrders({ status, page, limit }) {
  const where = status ? { status } : {};
  const [total, rows] = await prisma.$transaction([
    prisma.foodOrder.count({ where }),
    prisma.foodOrder.findMany({
      where,
      orderBy: [{ createdAt: 'desc' }, { id: 'asc' }],
      skip: (page - 1) * limit,
      take: limit,
      include: {
        user: { select: { id: true, name: true } },
        shop: { select: { id: true, name: true, slug: true } },
      },
    }),
  ]);
  return {
    items: rows.map((o) => ({ ...presentOrder(o), vendor: o.user, shop: o.shop })),
    pagination: { page, limit, total, totalPages: Math.ceil(total / limit) },
  };
}

export async function adminSetStatus(admin, id, status) {
  const updated = await prisma.$transaction(async (tx) => {
    const order = await tx.foodOrder.findUnique({ where: { id } });
    if (!order) throw new AppError(404, 'Food order not found');
    if (!NEXT[order.status].includes(status)) {
      throw new AppError(409, `A ${order.status.toLowerCase()} order cannot become ${status.toLowerCase()}`);
    }
    // the WHERE on the old status makes two admins clicking at the same time safe
    const res = await tx.foodOrder.updateMany({ where: { id, status: order.status }, data: { status } });
    if (res.count !== 1) throw new AppError(409, 'The order was changed meanwhile; reload and try again');
    await audit(tx, admin.id, 'food_order.status_changed', 'FoodOrder', id, { from: order.status, to: status });
    return tx.foodOrder.findUnique({ where: { id } });
  });

  await notify([updated.userId], {
    type: 'FOOD_ORDER_STATUS',
    title: 'Food order update',
    body: `Your ${updated.itemName} order is now ${updated.status.toLowerCase()}`,
    data: { foodOrderId: updated.id, status: updated.status },
  });
  return presentOrder(updated);
}

// ---------- admin: menu ----------

export async function adminListItems() {
  return prisma.foodItem.findMany({
    orderBy: [{ sortOrder: 'asc' }, { nameEn: 'asc' }],
    select: { ...ITEM_SELECT, sortOrder: true, createdAt: true, updatedAt: true },
  });
}

export async function adminCreateItem(admin, input) {
  const item = await prisma.foodItem.create({ data: input });
  await audit(prisma, admin.id, 'food_item.created', 'FoodItem', item.id, { nameEn: item.nameEn, price: item.price });
  return item;
}

export async function adminUpdateItem(admin, id, input) {
  const found = await prisma.foodItem.findUnique({ where: { id }, select: { id: true } });
  if (!found) throw new AppError(404, 'Food item not found');
  const item = await prisma.foodItem.update({ where: { id }, data: input });
  await audit(prisma, admin.id, 'food_item.updated', 'FoodItem', id, { fields: Object.keys(input) });
  return item;
}

// An item that was ever ordered stays (orders point at it): mark it unavailable instead.
export async function adminDeleteItem(admin, id) {
  const item = await prisma.foodItem.findUnique({ where: { id }, include: { _count: { select: { orders: true } } } });
  if (!item) throw new AppError(404, 'Food item not found');
  if (item._count.orders > 0) throw new AppError(409, 'This item has orders; set isAvailable to false instead');
  await prisma.$transaction([
    prisma.foodItem.delete({ where: { id } }),
    prisma.auditLog.create({ data: { actorId: admin.id, action: 'food_item.deleted', entityType: 'FoodItem', entityId: id, meta: { nameEn: item.nameEn } } }),
  ]);
}
