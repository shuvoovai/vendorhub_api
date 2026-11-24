import { z } from 'zod';

// Multipart sends every field as a string. An empty string on an optional field means "none" (null).
const blankToNull = (v) => (typeof v === 'string' && v.trim() === '' ? null : v);

// Plain text only: no HTML brackets, no control characters (line breaks included).
// eslint-disable-next-line no-control-regex
const PLAIN = /^[^<>\u0000-\u001f\u007f]*$/;
const text = (max) => z.string().trim().min(1).max(max).regex(PLAIN, 'Plain text only');
const optionalText = (max) => z.preprocess(blankToNull, text(max).nullable().optional());

// Internal paths only: "/..." but never "//..." (protocol-relative) or "/\..." (browsers read it as "//").
// The character list has no ":" or spaces, so "javascript:" / "data:" can never appear.
const HREF = /^\/(?![/\\])[A-Za-z0-9\-._~/?#=&%+]*$/;
const href = z.string().trim().max(200).regex(HREF, 'Must be an internal path starting with "/"');

const bool = z.preprocess((v) => (v === 'true' ? true : v === 'false' ? false : v), z.boolean());
const date = z.preprocess(blankToNull, z.coerce.date().nullable().optional());
const sortOrder = z.coerce.number().int().min(0).max(1000);

const fields = {
  titleEn: text(80),
  titleBn: text(80),
  textEn: optionalText(160),
  textBn: optionalText(160),
  ctaEn: optionalText(30),
  ctaBn: optionalText(30),
  href,
  sortOrder,
  isActive: bool,
  startsAt: date,
  endsAt: date,
};

const datesInOrder = (b) => !(b.startsAt && b.endsAt && b.endsAt <= b.startsAt);
const ORDER = { message: 'endsAt must be after startsAt', path: ['endsAt'] };

export const createBannerSchema = z
  .strictObject({ ...fields, sortOrder: sortOrder.optional(), isActive: bool.optional() })
  .refine(datesInOrder, ORDER);

export const updateBannerSchema = z
  .strictObject({
    ...Object.fromEntries(Object.entries(fields).map(([k, v]) => [k, v.optional()])),
    removeVideo: bool.optional(), // "true": delete the video (the photo stays)
  })
  .refine(datesInOrder, ORDER);

export const reorderSchema = z.strictObject({
  ids: z
    .array(z.string().uuid())
    .min(1)
    .max(100)
    .refine((ids) => new Set(ids).size === ids.length, 'Each id may appear only once'),
});

export const idParams = z.object({ id: z.string().uuid() });
