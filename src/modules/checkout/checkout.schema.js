import { z } from 'zod';

// bKash and Nagad: the customer sends the money to our merchant number (GET /payment-options) and tells us
// the wallet it came from (+ the TrxID if they have it), so an admin can verify it and mark the order paid.
export const WALLET_METHODS = ['BKASH', 'NAGAD'];

const paymentDetails = z
  .object({
    walletNumber: z.string().trim().regex(/^01[3-9]\d{8}$/, 'Enter the 11-digit wallet number, like 01XXXXXXXXX'),
    transactionId: z
      .string()
      .trim()
      .toUpperCase()
      .regex(/^[A-Z0-9]{8,12}$/, 'The transaction ID has 8 to 12 letters and digits')
      .optional(),
  })
  .strict(); // nothing else (and never card details): cards go ONLINE through the gateway's hosted page

const shopChoice = z
  .object({
    shopId: z.string().uuid(),
    deliveryMethod: z.enum(['STORE_PICKUP', 'VENDOR_DELIVERY']),
    paymentMethod: z.enum(['ONLINE', 'PAY_AT_STORE', 'CASH_ON_DELIVERY', 'BKASH', 'NAGAD']),
    paymentDetails: paymentDetails.optional(),
    deliveryAddress: z.string().trim().min(10).max(300).optional(),
    addressId: z.string().uuid().optional(), // a saved address of the customer, instead of typing one
  })
  .superRefine((c, ctx) => {
    const wallet = WALLET_METHODS.includes(c.paymentMethod);
    if (wallet && !c.paymentDetails) {
      ctx.addIssue({ code: 'custom', path: ['paymentDetails'], message: 'Payment details are required for bKash and Nagad' });
    }
    if (!wallet && c.paymentDetails) {
      ctx.addIssue({ code: 'custom', path: ['paymentDetails'], message: 'Payment details are only for bKash and Nagad' });
    }
  });

export const checkoutSchema = z.object({
  shops: z.array(shopChoice).min(1).max(20),
});

export const listOrdersQuery = z.object({
  status: z
    .enum(['PLACED', 'CONFIRMED', 'READY_FOR_PICKUP', 'OUT_FOR_DELIVERY', 'COMPLETED', 'CANCELLED'])
    .optional(),
  page: z.coerce.number().int().min(1).default(1),
  limit: z.coerce.number().int().min(1).max(50).default(10),
});
