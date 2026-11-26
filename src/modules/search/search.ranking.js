// Re-ranks the visual-search candidates with the (optional) AI answer. Pure functions, no I/O, so the
// rules can be checked without the model or the database (scripts/check-photo-ranking.mjs).
export const CANDIDATES = 48; // fetched from the database by CLIP score
export const RESULTS = 12; // returned
// Photo-to-text similarities are much lower than photo-to-photo ones: map 0.20..0.35 onto 0..0.85.
export const TITLE_FLOOR = 0.2;
export const TITLE_SPAN = 0.15;
export const TITLE_MAX = 0.85;
const CATEGORY_BONUS = 0.1; // the AI's category or one of its children
const WORDS_BONUS = 0.1; // all AI search words found in the brand + title
const MIN_AFTER_FILTER = 4; // fewer left: the other top-level categories are kept

const clamp = (n, lo, hi) => Math.min(hi, Math.max(lo, Number.isFinite(n) ? n : 0));

export const titleScore = (raw) => clamp((raw - TITLE_FLOOR) / TITLE_SPAN, 0, 1) * TITLE_MAX;

// lowercase words of 2+ letters/digits ("A55-5G (8/128GB)" -> a55, 5g, 128gb)
const wordsOf = (text) =>
  new Set(
    String(text ?? '')
      .toLowerCase()
      .split(/[^\p{L}\p{N}]+/u)
      .filter((w) => w.length > 1),
  );

function topLevelOf(id, parentOf) {
  let current = id;
  for (let depth = 0; depth < 10 && parentOf.get(current); depth += 1) current = parentOf.get(current);
  return current;
}

/**
 * candidates: [{ id, title, brand, categoryId, photoScore, titleRaw, ... }] (scores are cosine similarities)
 * hint: { query, categoryId, categories: [{ id, parentId }] } from the AI answer, or null
 * Returns the best `limit` candidates with `score` (0..1) and `match` ('photo' | 'title') added.
 */
export function rankCandidates(candidates, hint, limit = RESULTS) {
  const categories = hint?.categories ?? [];
  const categoryId = hint?.categoryId ?? null;
  const parentOf = new Map(categories.map((c) => [c.id, c.parentId ?? null]));
  const boosted = new Set(categoryId ? [categoryId, ...categories.filter((c) => c.parentId === categoryId).map((c) => c.id)] : []);
  const queryWords = [...wordsOf(hint?.query)];

  let pool = candidates;
  if (categoryId) {
    const top = topLevelOf(categoryId, parentOf);
    const sameTop = candidates.filter((c) => topLevelOf(c.categoryId, parentOf) === top);
    if (sameTop.length >= MIN_AFTER_FILTER) pool = sameTop;
  }

  return pool
    .map((c) => {
      const photo = clamp(c.photoScore, 0, 1);
      const title = titleScore(c.titleRaw);
      let score = Math.max(photo, title);
      if (boosted.has(c.categoryId)) score += CATEGORY_BONUS;
      if (queryWords.length) {
        const have = wordsOf(`${c.brand ?? ''} ${c.title ?? ''}`);
        score += (WORDS_BONUS * queryWords.filter((w) => have.has(w)).length) / queryWords.length;
      }
      return { ...c, match: photo >= title ? 'photo' : 'title', score: Math.min(1, score) };
    })
    .sort((a, b) => b.score - a.score || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0))
    .slice(0, limit);
}
