// Listing variants (color, size, ...): shared rules for listings, catalog, cart and checkout.
import { AppError } from './errors.js';

export const MAX_OPTIONS = 3;

const norm = (s) => s.trim().toLowerCase();

/** "Red / M": the values in option order. */
export const variantLabel = (variantOptions, options) =>
  (variantOptions ?? []).map((o) => options?.[o.name]).filter((v) => v !== undefined).join(' / ');

/** Unique key of a combination: lowercased values in option order, e.g. "red|m". */
export const optionsKey = (variantOptions, options) => variantOptions.map((o) => norm(options[o.name])).join('|');

/** Availability from a stock number (same thresholds as listings). */
export function deriveAvailability(stockQty) {
  if (stockQty === null || stockQty === undefined) return 'AVAILABLE';
  if (stockQty === 0) return 'OUT_OF_STOCK';
  if (stockQty <= 5) return 'LIMITED';
  return 'IN_STOCK';
}

/** A variant's public availability: its own stock when counted, else the listing's. */
export function variantAvailability(listing, variant) {
  if (listing.availability === 'OUT_OF_STOCK') return 'OUT_OF_STOCK';
  return variant.stockQty === null ? listing.availability : deriveAvailability(variant.stockQty);
}

/** The price a buyer pays before deals and bargains. */
export const basePrice = (listing, variant) => variant?.price ?? listing.price;

/**
 * Checks variantOptions + variants (the shape is already checked by Zod) and returns them normalised:
 * names and values trimmed, option names matched case-insensitively, each variant's options keyed by the
 * option's own spelling, plus its optionsKey. countsStock: the listing counts stock (stockQty not null).
 */
export function checkVariants(variantOptions, variants, { countsStock }) {
  const names = new Set();
  const options = variantOptions.map((o) => {
    const name = o.name.trim();
    if (names.has(norm(name))) throw new AppError(400, 'Option names must be unique');
    names.add(norm(name));
    const seen = new Set();
    const values = o.values.map((v) => v.trim());
    for (const v of values) {
      if (seen.has(norm(v))) throw new AppError(400, `The values of "${name}" must be unique`);
      seen.add(norm(v));
    }
    return { name, values };
  });

  if (options.length === 0) {
    if (variants.length > 0) throw new AppError(400, 'Variants need variantOptions');
    return { options, variants: [] };
  }
  if (variants.length === 0) throw new AppError(400, 'Send the variants for these options');

  const keys = new Set();
  const out = variants.map((v) => {
    const given = Object.entries(v.options).map(([k, val]) => [norm(k), String(val).trim()]);
    if (given.length !== options.length) throw new AppError(400, 'Every variant needs exactly one value for each option');
    const byName = new Map(given);
    if (byName.size !== given.length) throw new AppError(400, 'Every variant needs exactly one value for each option');
    const picked = {};
    for (const o of options) {
      const raw = byName.get(norm(o.name));
      if (raw === undefined) throw new AppError(400, 'Every variant needs exactly one value for each option');
      const value = o.values.find((x) => norm(x) === norm(raw));
      if (!value) throw new AppError(400, `A variant uses a value that is not in "${o.name}"`);
      picked[o.name] = value;
    }
    const key = optionsKey(options, picked);
    if (keys.has(key)) throw new AppError(400, 'Each combination may appear only once');
    keys.add(key);
    if (countsStock && (v.stockQty === null || v.stockQty === undefined)) {
      throw new AppError(400, 'This listing counts stock: every variant needs a stockQty');
    }
    if (!countsStock && v.stockQty !== null && v.stockQty !== undefined) {
      throw new AppError(400, 'This listing does not count stock: leave the variant stockQty empty');
    }
    return { options: picked, optionsKey: key, price: v.price ?? null, stockQty: countsStock ? v.stockQty : null, isActive: v.isActive ?? true };
  });
  if (!out.some((v) => v.isActive)) throw new AppError(400, 'At least one variant must be active');
  return { options, variants: out };
}
