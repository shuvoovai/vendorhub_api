import { z } from 'zod';
import { plainText, optionalPlainText, bdPhone } from '../../lib/plainText.js';

export const FOOD_STATUSES = ['PENDING', 'CONFIRMED', 'DELIVERED', 'CANCELLED'];

// Vendor order. Only ids and quantities come from the client; unknown keys (price, total, unitPrice,
// shopId...) are dropped by z.object, so a client-sent price can never be used.
export const createFoodOrderSchema = z.object({
  itemId: z.string().uuid(),
  quantity: z.number().int().min(1).max(20),
  name: plainText(2, 80),
  phone: bdPhone,
  address: plainText(5, 300, { multiline: true }),
  note: optionalPlainText(300, { multiline: true }),
});

export const adminFoodOrdersQuery = z.object({
  status: z.enum(FOOD_STATUSES).optional(),
  page: z.coerce.number().int().min(1).default(1),
  limit: z.coerce.number().int().min(1).max(100).default(20),
});

export const foodOrderStatusSchema = z.strictObject({ status: z.enum(FOOD_STATUSES) });

// ---------- menu (admin) ----------
const emoji = z.preprocess((v) => (typeof v === 'string' ? v.trim() : v), z.string().max(8).nullable());
const description = z.preprocess((v) => (v === '' ? null : v), plainText(1, 120).nullable());

const itemFields = {
  nameEn: plainText(1, 60),
  nameBn: plainText(1, 60),
  descriptionEn: description.optional(),
  descriptionBn: description.optional(),
  price: z.number().int().min(1).max(100000),
  emoji: emoji.optional(),
  isAvailable: z.boolean().optional(),
  sortOrder: z.number().int().min(0).max(1000).optional(),
};

export const createFoodItemSchema = z.strictObject(itemFields);
export const updateFoodItemSchema = z
  .strictObject(Object.fromEntries(Object.entries(itemFields).map(([k, v]) => [k, v.optional()])))
  .refine((o) => Object.keys(o).length > 0, { message: 'Provide at least one field to update' });

export const idParams = z.object({ id: z.string().uuid() });
