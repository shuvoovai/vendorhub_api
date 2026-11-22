// Plain text from the public: trimmed, control characters removed (line breaks kept only where
// allowed), and anything that looks like an HTML tag rejected. Used by Zod schemas.
import { z } from 'zod';

// eslint-disable-next-line no-control-regex
const CONTROL = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g; // keeps \t \n \r
// eslint-disable-next-line no-control-regex
const CONTROL_AND_BREAKS = /[\u0000-\u001f\u007f]/g;
const TAG = /<\s*[a-z!/?]/i; // "<b>", "</p>", "<!--", "<?php"; a plain "< 5 min" is fine

const clean = (multiline) => (v) =>
  typeof v === 'string' ? v.replace(multiline ? CONTROL : CONTROL_AND_BREAKS, '').trim() : v;

/** A required plain-text field. multiline: keep line breaks (descriptions). */
export const plainText = (min, max, { multiline = false } = {}) =>
  z.preprocess(clean(multiline), z.string().min(min).max(max).refine((s) => !TAG.test(s), 'Plain text only'));

/** An optional plain-text field; an empty string counts as "not given". */
export const optionalPlainText = (max, opts) =>
  z.preprocess((v) => (typeof v === 'string' && clean(opts?.multiline)(v) === '' ? undefined : v), plainText(1, max, opts).optional());

// Bangladeshi mobile number: 01 + operator digit 3-9 + 8 digits
export const bdPhone = z.preprocess((v) => (typeof v === 'string' ? v.trim() : v), z.string().regex(/^01[3-9]\d{8}$/, 'Invalid phone number'));
