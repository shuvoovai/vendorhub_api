import { z } from 'zod';

const availability = z.enum(['IN_STOCK', 'LIMITED', 'AVAILABLE', 'OUT_OF_STOCK']);
// who may see the stock number (src/lib/stockVisibility.js); default HIDDEN
export const stockVisibility = z.enum(['PUBLIC', 'VENDORS', 'HIDDEN']);

// Variants: options (max 3, each 1-20 values) and the combinations offered. Deeper checks (unique names,
// one value per option, no duplicate combinations, stock rules) are in src/lib/variants.js.
const label = z.string().trim().min(1).max(30);
const variantOptions = z
  .array(z.strictObject({ name: label, values: z.array(label).min(1).max(20) }))
  .max(3);
const variants = z
  .array(
    z.strictObject({
      options: z.record(z.string().max(30), z.string().max(30)),
      price: z.number().int().min(1).nullable().optional(), // null = the listing price
      stockQty: z.number().int().min(0).nullable().optional(),
      isActive: z.boolean().optional(),
    }),
  )
  .max(200);
// both or neither: [] and [] turn variants off
const bothOrNeither = (o) => (o.variantOptions === undefined) === (o.variants === undefined);
const BOTH = { message: 'Send variantOptions and variants together', path: ['variants'] };

export const createListingSchema = z.object({
  productId: z.string().uuid(),
  price: z.number().int().min(1),
  availability: availability.optional(), // derived from stockQty if omitted
  stockQty: z.number().int().min(0).nullable().optional(),
  stockVisibility: stockVisibility.optional(),
  bargainEnabled: z.boolean().default(false),
  minOfferPercent: z.number().int().min(50).max(100).default(92),
  variantOptions: variantOptions.optional(),
  variants: variants.optional(),
}).refine(bothOrNeither, BOTH);

// Written out explicitly (no .partial()) so defaults never overwrite fields on PATCH.
export const updateListingSchema = z
  .object({
    price: z.number().int().min(1).optional(),
    availability: availability.optional(),
    stockQty: z.number().int().min(0).nullable().optional(),
    stockVisibility: stockVisibility.optional(),
    bargainEnabled: z.boolean().optional(),
    minOfferPercent: z.number().int().min(50).max(100).optional(),
    isActive: z.boolean().optional(),
    variantOptions: variantOptions.optional(),
    variants: variants.optional(),
  })
  .refine((o) => Object.keys(o).length > 0, { message: 'Provide at least one field to update' })
  .refine(bothOrNeither, BOTH);