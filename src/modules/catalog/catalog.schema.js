import { z } from 'zod';

export const listProductsQuery = z.object({
  q: z.string().trim().min(1).optional(),
  category: z.string().trim().min(1).optional(), // category slug (includes its children)
  brand: z.string().trim().min(1).optional(), // brand name
  minPrice: z.coerce.number().int().min(0).optional(),
  maxPrice: z.coerce.number().int().min(0).optional(),
  shopId: z.string().uuid().optional(),
  marketId: z.string().uuid().optional(),
  availableOnly: z.enum(['true', 'false']).transform((v) => v === 'true').optional(),
  newSinceDays: z.coerce.number().int().min(1).max(60).optional(), // only products added in the last N days
  sort: z.enum(['newest', 'price_asc', 'price_desc', 'popular']).default('newest'),
  page: z.coerce.number().int().min(1).default(1),
  limit: z.coerce.number().int().min(1).max(50).default(12),
});

export const followingFeedQuery = z.object({
  scope: z.enum(['followed', 'unfollowed']).default('followed'),
  page: z.coerce.number().int().min(1).default(1),
  limit: z.coerce.number().int().min(1).max(24).default(8),
});

export const productDetailQuery = z.object({
  listingId: z.string().uuid().optional(),
});

export const categoriesQuery = z.object({
  // true: only top-level categories (home page), product counts include their subcategories
  topLevel: z.enum(['true', 'false']).transform((v) => v === 'true').optional(),
});
