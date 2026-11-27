import { z } from 'zod';
import { PRO_MONTHS } from '../../config/plans.js';

const STATUSES = ['PENDING', 'APPROVED', 'REJECTED'];

// The owner paid by bKash / Nagad to our merchant number (GET /payment-options) and tells us from which
// wallet and the TrxID. The amount is NOT sent: the server takes it from src/config/plans.js.
export const createRequestSchema = z.strictObject({
  plan: z.literal('PRO'),
  months: z
    .number()
    .int()
    .refine((m) => PRO_MONTHS.includes(m), { message: `months must be one of ${PRO_MONTHS.join(', ')}` }),
  method: z.enum(['BKASH', 'NAGAD']),
  walletNumber: z.string().trim().regex(/^01\d{9}$/, 'Enter the 11-digit wallet number, like 01XXXXXXXXX'),
  transactionId: z
    .string()
    .trim()
    .regex(/^[A-Za-z0-9]{8,12}$/, 'The transaction ID has 8 to 12 letters and digits')
    .transform((s) => s.toUpperCase()),
});

export const adminRequestsQuery = z.object({
  status: z.enum(STATUSES).optional(),
  page: z.coerce.number().int().min(1).default(1),
  limit: z.coerce.number().int().min(1).max(100).default(20),
});

// a rejection must say why (the shop owner sees the reason)
export const reviewRequestSchema = z.discriminatedUnion('decision', [
  z.strictObject({ decision: z.literal('APPROVE') }),
  z.strictObject({ decision: z.literal('REJECT'), reason: z.string().trim().min(3).max(300) }),
]);

const uuid = z.string().uuid();
export const shopParams = z.object({ shopId: uuid });
export const shopRequestParams = z.object({ shopId: uuid, id: uuid });
export const requestParams = z.object({ id: uuid });
