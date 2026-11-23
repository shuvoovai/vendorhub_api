import { z } from 'zod';

const bool = z.enum(['true', 'false']).transform((v) => v === 'true');

export const listShopsQuery = z.object({
  q: z.string().trim().min(1).optional(),
  verificationLevel: z
    .enum(['UNVERIFIED', 'DOCUMENTS_VERIFIED', 'BUSINESS_VERIFIED', 'PHYSICAL_SHOP_VERIFIED', 'TRUSTED_VENDOR'])
    .optional(),
  isActive: bool.optional(),
  marketId: z.string().uuid().optional(),
  page: z.coerce.number().int().min(1).default(1),
  limit: z.coerce.number().int().min(1).max(50).default(20),
});

export const shopStatusSchema = z.object({
  isActive: z.boolean(),
  reason: z.string().trim().min(5).max(500),
});

export const salesQuery = z.object({
  from: z.coerce.date().optional(),
  to: z.coerce.date().optional(),
  interval: z.enum(['day', 'week', 'month']).default('day'),
});

export const topQuery = z.object({
  from: z.coerce.date().optional(),
  to: z.coerce.date().optional(),
  limit: z.coerce.number().int().min(1).max(20).default(5),
});

export const listOrdersQuery = z.object({
  status: z.enum(['CONFIRMED', 'READY_FOR_PICKUP', 'OUT_FOR_DELIVERY', 'COMPLETED', 'CANCELLED']).optional(),
  page: z.coerce.number().int().min(1).default(1),
  limit: z.coerce.number().int().min(1).max(50).default(20),
});

export const updateOrderSchema = z
  .object({
    status: z.enum(['READY_FOR_PICKUP', 'OUT_FOR_DELIVERY', 'COMPLETED', 'CANCELLED']).optional(),
    paymentStatus: z.enum(['PAID', 'REFUNDED']).optional(),
  })
  .strict()
  .refine((b) => b.status || b.paymentStatus, { message: 'Send status or paymentStatus' });
