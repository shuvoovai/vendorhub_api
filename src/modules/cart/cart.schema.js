import { z } from 'zod';

export const addItemSchema = z.object({
  listingId: z.string().uuid(),
  variantId: z.string().uuid().optional(), // required when the listing has active variants
  quantity: z.number().int().min(1).max(10).default(1),
});

export const updateItemSchema = z.object({
  quantity: z.number().int().min(1).max(10),
});
export const itemParams = z.object({ itemId: z.string().uuid() });
