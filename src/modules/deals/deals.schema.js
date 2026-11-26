import { z } from 'zod';

export const MAX_DEAL_DAYS = 7;
const MAX_MS = MAX_DEAL_DAYS * 24 * 60 * 60 * 1000;

const price = z.number().int().min(1).max(10_000_000);
const date = z.coerce.date();
const stockLimit = z.number().int().min(1).max(100_000).nullable();

// Checked here when both dates are in the body; the service checks again with the stored values.
const datesOk = (d) => !(d.startsAt && d.endsAt) || (d.endsAt > d.startsAt && d.endsAt - d.startsAt <= MAX_MS);
const DATES = { message: `endsAt must be after startsAt and at most ${MAX_DEAL_DAYS} days later`, path: ['endsAt'] };

export const createDealSchema = z
  .strictObject({
    listingId: z.string().uuid(),
    dealPrice: price,
    startsAt: date,
    endsAt: date,
    stockLimit: stockLimit.optional(),
    isActive: z.boolean().optional(),
  })
  .refine(datesOk, DATES);

export const updateDealSchema = z
  .strictObject({
    dealPrice: price.optional(),
    startsAt: date.optional(),
    endsAt: date.optional(),
    stockLimit: stockLimit.optional(),
    isActive: z.boolean().optional(),
  })
  .refine((o) => Object.keys(o).length > 0, { message: 'Provide at least one field to update' })
  .refine(datesOk, DATES);

export const flashQuery = z.object({
  limit: z.coerce.number().int().min(1).max(20).default(10),
});

export const adminDealsQuery = z.object({
  status: z.enum(['PENDING', 'APPROVED', 'REJECTED']).optional(),
  page: z.coerce.number().int().min(1).default(1),
  limit: z.coerce.number().int().min(1).max(100).default(20),
});

// an admin's decision on a PENDING deal; a rejection must say why (the shop sees the reason)
export const reviewDealSchema = z
  .strictObject({
    decision: z.enum(['APPROVE', 'REJECT']),
    reason: z.string().trim().min(5).max(300).optional(),
  })
  .refine((o) => o.decision !== 'REJECT' || o.reason, { message: 'A reason is required to reject a deal', path: ['reason'] });

const uuid = z.string().uuid();
export const shopParams = z.object({ shopId: uuid });
export const shopDealParams = z.object({ shopId: uuid, id: uuid });
export const dealParams = z.object({ id: uuid });
