// Checks the search-by-photo re-ranking rules with made-up candidates (no model, no database).
// Prints one "PASS name" / "FAIL name" line per check; used by test-image-search.ps1.
import { rankCandidates, titleScore } from '../src/modules/search/search.ranking.js';

const categories = [
  { id: 'phones', parentId: null },
  { id: 'rugged', parentId: 'phones' },
  { id: 'computers', parentId: null },
  { id: 'laptops', parentId: 'computers' },
];
const hint = (query, categoryId) => ({ query, categoryId, categories });
const item = (id, categoryId, photoScore, title = 'Product', brand = null, titleRaw = 0) => ({ id, categoryId, photoScore, titleRaw, title, brand });
const ids = (list) => list.map((r) => r.id);
const check = (name, ok) => console.log(`${ok ? 'PASS' : 'FAIL'} ${name}`);
const near = (a, b) => Math.abs(a - b) < 1e-9;

// the main rule: a mocked AI answer "phones" lifts a phone above a laptop whose photo is more similar
{
  const r = rankCandidates([item('laptop', 'laptops', 0.85, 'Laptop 15'), item('phone', 'phones', 0.8, 'Galaxy A55', 'Samsung'), item('l2', 'laptops', 0.5), item('l3', 'laptops', 0.4)], hint('samsung galaxy phone', 'phones'));
  check('the matching category ranks above a more similar photo from another category', r[0].id === 'phone' && ids(r).indexOf('laptop') === 1);
  check('category and word bonus added (0.80 + 0.10 + 2/3 of 0.10)', near(r[0].score, 0.8 + 0.1 + 0.1 * (2 / 3)));
  check('fewer than 4 left in the category: the other categories are kept', r.length === 4);
}
// without the AI answer, pure CLIP order
{
  const r = rankCandidates([item('laptop', 'laptops', 0.85), item('phone', 'phones', 0.8)], null);
  check('no AI answer: the more similar photo wins', r[0].id === 'laptop' && near(r[0].score, 0.85));
}
// 4+ left in the same top-level category: the others are dropped; children get the bonus
{
  const r = rankCandidates(
    [item('laptop', 'laptops', 0.99), item('p1', 'phones', 0.7), item('p2', 'phones', 0.6), item('p3', 'rugged', 0.65), item('p4', 'phones', 0.5)],
    hint('x', 'phones'),
  );
  check('other top-level categories dropped when 4 or more are left', !ids(r).includes('laptop') && r.length === 4);
  check('a child of the AI category gets the category bonus', near(r.find((x) => x.id === 'p3').score, 0.75));
}
// a child category from the AI: the parent's top-level tree is kept
{
  const r = rankCandidates([item('a', 'phones', 0.5), item('b', 'rugged', 0.5), item('c', 'phones', 0.4), item('d', 'phones', 0.3), item('e', 'laptops', 0.9)], hint('x', 'rugged'));
  check('the AI child category keeps its whole top-level tree', r.length === 4 && r[0].id === 'b');
}
// score limits and title normalisation
{
  const r = rankCandidates([item('a', 'phones', 0.97, 'Galaxy', 'Samsung')], hint('samsung galaxy', 'phones'));
  check('the score never goes above 1', r[0].score === 1);
  check('title similarity 0.20 or less counts as 0', titleScore(0.2) === 0 && titleScore(0.1) === 0);
  check('title similarity 0.35 or more counts as 0.85', near(titleScore(0.35), 0.85) && near(titleScore(0.5), 0.85));
  check('title similarity 0.275 counts as 0.425', near(titleScore(0.275), 0.425));
  const t = rankCandidates([item('t', 'phones', 0.3, 'Product', null, 0.3)], null);
  check('a title match is reported as match title', t[0].match === 'title' && near(t[0].score, 0.85 * (0.1 / 0.15)));
}
// one-letter words are ignored
{
  const r = rankCandidates([item('a', 'phones', 0.5, 'Galaxy A55')], hint('a b galaxy', null));
  check('one-letter words are ignored in the word bonus', near(r[0].score, 0.6));
}
// at most 12 results
{
  const many = Array.from({ length: 48 }, (_, i) => item(`p${String(i).padStart(2, '0')}`, 'phones', i / 100));
  const r = rankCandidates(many, null);
  check('at most 12 results, best first', r.length === 12 && r[0].id === 'p47');
}
