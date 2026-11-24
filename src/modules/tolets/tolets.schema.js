import { z } from 'zod';
import { plainText, optionalPlainText, bdPhone } from '../../lib/plainText.js';

export const TOLET_TYPES = ['SHOP', 'SHOWROOM', 'KIOSK', 'FOOD_COURT', 'WAREHOUSE'];
export const TOLET_STATUSES = ['PENDING', 'APPROVED', 'REJECTED'];

// Today's date in Bangladesh (YYYY-MM-DD), so "from today" matches what the submitter sees.
export const dhakaToday = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Dhaka' }).format(new Date());
const addYear = (ymd) => `${Number(ymd.slice(0, 4)) + 1}${ymd.slice(4)}`;

const availableFrom = z
  .string()
  .regex(/^\d{4}-\d{2}-\d{2}$/, 'Use YYYY-MM-DD')
  .refine((d) => !Number.isNaN(Date.parse(`${d}T00:00:00Z`)) && new Date(`${d}T00:00:00Z`).toISOString().startsWith(d), 'Invalid date')
  .refine((d) => d >= dhakaToday() && d <= addYear(dhakaToday()), 'availableFrom must be between today and one year ahead');

const optionalInt = (min, max) => z.number().int().min(min).max(max).optional();

// strict: unknown keys (status, userId, expiresAt...) are rejected with 400
export const createToletSchema = z.strictObject({
  type: z.enum(TOLET_TYPES),
  title: plainText(5, 100),
  marketName: optionalPlainText(80),
  floor: optionalPlainText(20),
  area: plainText(2, 60),
  address: plainText(5, 200),
  rent: z.number().int().min(100).max(9_999_999),
  advance: optionalInt(0, 99_999_999),
  sizeSqft: optionalInt(1, 100_000),
  availableFrom,
  contactName: plainText(2, 80),
  contactPhone: bdPhone,
  description: optionalPlainText(1000, { multiline: true }),
  website: z.string().max(500).optional(), // honeypot: people leave it empty
});

export const listToletsQuery = z.object({
  type: z.enum(TOLET_TYPES).optional(),
  area: z.string().trim().min(1).max(60).optional(),
  page: z.coerce.number().int().min(1).default(1),
  limit: z.coerce.number().int().min(1).max(24).default(8),
});

export const adminToletsQuery = z.object({
  status: z.enum(TOLET_STATUSES).optional(),
  page: z.coerce.number().int().min(1).default(1),
  limit: z.coerce.number().int().min(1).max(100).default(20),
});

export const reviewToletSchema = z
  .strictObject({
    status: z.enum(['APPROVED', 'REJECTED']),
    reason: optionalPlainText(300, { multiline: true }),
  })
  .refine((b) => b.status !== 'REJECTED' || b.reason, { message: 'A reason is required when rejecting', path: ['reason'] });

export const idParams = z.object({ id: z.string().uuid() });

// ---------- inquiries (visit requests) ----------

export const INQUIRY_TIMES = ['MORNING', 'AFTERNOON', 'EVENING'];
export const INQUIRY_STATUSES = ['NEW', 'CONTACTED', 'CLOSED'];
const addDays = (ymd, n) => new Date(Date.parse(`${ymd}T00:00:00Z`) + n * 86_400_000).toISOString().slice(0, 10);

const preferredDate = z
  .string()
  .regex(/^\d{4}-\d{2}-\d{2}$/, 'Use YYYY-MM-DD')
  .refine((d) => !Number.isNaN(Date.parse(`${d}T00:00:00Z`)) && new Date(`${d}T00:00:00Z`).toISOString().startsWith(d), 'Invalid date')
  .refine((d) => d >= dhakaToday() && d <= addDays(dhakaToday(), 90), 'preferredDate must be between today and 90 days ahead');

export const createInquirySchema = z.strictObject({
  name: plainText(2, 80),
  phone: bdPhone,
  preferredDate,
  preferredTime: z.enum(INQUIRY_TIMES),
  message: optionalPlainText(500, { multiline: true }),
  website: z.string().max(500).optional(), // honeypot
});

export const adminInquiriesQuery = z.object({ status: z.enum(INQUIRY_STATUSES).optional() });

export const updateInquirySchema = z.strictObject({ status: z.enum(INQUIRY_STATUSES) });
