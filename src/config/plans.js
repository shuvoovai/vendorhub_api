// Vendor subscription plans. Prices and limits live ONLY here: the API never trusts them from the client
// (a subscription request stores the amount from this file at request time).
// maxListings: active listings a shop may have (null = unlimited). prices: BDT for that many months.
export const PLANS = Object.freeze({
  FREE: Object.freeze({
    code: 'FREE',
    maxListings: 20,
    flashDeals: false,
    featuredBadge: false,
    prices: Object.freeze([]),
  }),
  PRO: Object.freeze({
    code: 'PRO',
    maxListings: null,
    flashDeals: true,
    featuredBadge: true,
    prices: Object.freeze([
      Object.freeze({ months: 1, amount: 500 }),
      Object.freeze({ months: 3, amount: 1350 }),
      Object.freeze({ months: 6, amount: 2500 }),
      Object.freeze({ months: 12, amount: 4800 }),
    ]),
  }),
});

export const PLAN_CODES = Object.keys(PLANS);
export const PRO_MONTHS = PLANS.PRO.prices.map((p) => p.months);

/** The configured price for a number of PRO months, or undefined when that period is not sold. */
export const proPrice = (months) => PLANS.PRO.prices.find((p) => p.months === months)?.amount;
