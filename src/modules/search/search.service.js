// Search by photo. Always: free visual search with CLIP on our own server (similar product photos
// and matching titles). Optional: search words + category from Gemini (SEARCH_IMAGE_MODE=gemini) or a
// fixed test answer (mock), used to re-rank the visual candidates. The photo is never stored or logged.
import { prisma } from '../../lib/prisma.js';
import { AppError } from '../../lib/errors.js';
import { logger } from '../../lib/logger.js';
import { env } from '../../config/env.js';
import { processImage } from '../../lib/images.js';
import { thumbFor } from '../../lib/storage.js';
import { embedImage, toVectorLiteral } from '../../lib/clip.js';
import { bestListingIds } from '../catalog/catalog.service.js';
import { identifyProduct } from '../../lib/imageSearch.js';
import { CANDIDATES, TITLE_FLOOR, TITLE_SPAN, TITLE_MAX, rankCandidates } from './search.ranking.js';

// Untrusted model text: no control characters, single spaces, limited length.
const clean = (value, max) =>
  typeof value === 'string' ? value.replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, max) : '';

// Optional search words. Never fails the request: on any AI problem the words are simply null.
// words: what the client sees; hint: what the ranking uses (cleaned query, our own category id + tree).
async function describe(processed) {
  const none = { words: { query: null, label: null, category: null }, hint: null };
  if (env.SEARCH_IMAGE_MODE === 'off') return none;
  try {
    const categories = await prisma.category.findMany({ select: { id: true, name: true, slug: true, parentId: true } });
    const raw = await identifyProduct({ buffer: processed.full, mimeType: 'image/webp', categoryNames: categories.map((c) => c.name) });
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return none;
    const query = clean(raw.query, 100).replace(/[^\p{L}\p{N}\s-]/gu, '').replace(/\s+/g, ' ').trim().slice(0, 100);
    if (query.length < 2) return none;
    const hint = clean(raw.categoryHint, 100).toLowerCase();
    const category = hint ? categories.find((c) => c.name.toLowerCase() === hint) : null;
    return {
      words: {
        query,
        label: clean(raw.label, 80) || query.slice(0, 80),
        category: category ? { slug: category.slug, name: category.name } : null,
      },
      hint: { query, categoryId: category?.id ?? null, categories },
    };
  } catch (err) {
    logger.warn({ err: err.message }, 'search words unavailable; visual results only');
    return none;
  }
}

// Visual candidates: the best of photo similarity and (normalised) title similarity, active products only.
async function visualCandidates(buffer) {
  let vector;
  try {
    vector = await embedImage(buffer);
  } catch (err) {
    logger.error({ err: err.message }, 'visual search model unavailable');
    throw new AppError(503, 'Search by photo is not available right now. Please try again later.');
  }
  const v = toVectorLiteral(vector);
  const rows = await prisma.$queryRaw`
    WITH photo AS (
      SELECT i."productId", MAX(1 - (i.embedding <=> ${v}::vector)) AS score
      FROM "Image" i
      WHERE i."productId" IS NOT NULL AND i.embedding IS NOT NULL
      GROUP BY i."productId"
    ), scored AS (
      SELECT p.id, p.slug, p.title, p.images[1] AS image, p."categoryId", p."brandId",
             COALESCE(photo.score, 0) AS "photoScore",
             COALESCE(1 - (p."titleEmbedding" <=> ${v}::vector), 0) AS "titleRaw"
      FROM "Product" p
      LEFT JOIN photo ON photo."productId" = p.id
      WHERE p."isActive" = true AND (photo.score IS NOT NULL OR p."titleEmbedding" IS NOT NULL)
    )
    SELECT s.id, s.slug, s.title, s.image, s."categoryId", s."photoScore", s."titleRaw", b.name AS brand, l.lowest, l.shops
    FROM scored s
    JOIN LATERAL (
      SELECT MIN(sl.price) AS lowest, COUNT(*)::int AS shops
      FROM "ShopListing" sl
      JOIN "Shop" sh ON sh.id = sl."shopId"
      WHERE sl."productId" = s.id AND sl."isActive" = true AND sh."isActive" = true
    ) l ON l.shops > 0
    LEFT JOIN "Brand" b ON b.id = s."brandId"
    ORDER BY GREATEST(s."photoScore",
             LEAST(GREATEST((s."titleRaw" - ${TITLE_FLOOR}::float8) / ${TITLE_SPAN}::float8, 0), 1) * ${TITLE_MAX}::float8) DESC, s.id
    LIMIT ${CANDIDATES}`;
  return rows.map((r) => ({ ...r, photoScore: Number(r.photoScore), titleRaw: Number(r.titleRaw) }));
}

// Re-ranks the candidates with the AI hint (category, search words) and shapes the product cards.
async function similarProducts(candidates, hint) {
  const ranked = rankCandidates(candidates, hint);
  const best = await bestListingIds(ranked.map((r) => r.id));
  return ranked.map((r) => ({
    id: r.id,
    slug: r.slug,
    title: r.title,
    image: r.image ?? null,
    thumbnail: r.image ? thumbFor(r.image) : null,
    lowestPrice: r.lowest,
    shopCount: r.shops,
    bestListingId: best.get(r.id)?.id ?? null,
    hasVariants: best.get(r.id)?.hasVariants ?? false,
    match: r.match,
    score: Math.round(r.score * 1000) / 1000,
  }));
}

export async function searchByImage(file) {
  if (!file) throw new AppError(400, 'Send exactly one photo in the multipart field "photo"');
  // type from content + decoder check; re-encoded and small, no EXIF/GPS
  const processed = await processImage(file.buffer, 'SEARCH');
  // the AI answer and the CLIP candidates in parallel (describe never fails)
  const [{ words, hint }, candidates] = await Promise.all([describe(processed), visualCandidates(processed.full)]);
  return { ...words, products: await similarProducts(candidates, hint) };
}
