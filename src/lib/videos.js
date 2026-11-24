// Video type check from the file's first bytes (never the extension or the Content-Type header).
// Only MP4 and WebM are accepted. Videos are stored as uploaded (no re-encoding), under a random name.

// MP4 brands browsers play as video/mp4. HEIC/AVIF images ("heic", "mif1", "avif") and QuickTime ("qt  ")
// also start with "ftyp" and are refused here.
const MP4_BRANDS = new Set(['isom', 'iso2', 'iso3', 'iso4', 'iso5', 'iso6', 'mp41', 'mp42', 'avc1', 'dash', 'M4V ', 'mmp4', 'MSNV']);
const EBML = Buffer.from([0x1a, 0x45, 0xdf, 0xa3]);
const DOCTYPE = Buffer.from([0x42, 0x82]); // EBML DocType element id

/** @returns {'mp4' | 'webm' | null} */
export function detectVideo(buf) {
  if (!Buffer.isBuffer(buf) || buf.length < 16) return null;
  if (buf.toString('latin1', 4, 8) === 'ftyp' && MP4_BRANDS.has(buf.toString('latin1', 8, 12))) return 'mp4';
  if (buf.subarray(0, 4).equals(EBML)) {
    // The DocType must say "webm" (a generic Matroska .mkv says "matroska").
    const head = buf.subarray(0, 64);
    const at = head.indexOf(DOCTYPE);
    if (at !== -1 && head.subarray(at + 2, at + 2 + 9).includes(Buffer.from('webm'))) return 'webm';
  }
  return null;
}

export const VIDEO_TYPES = Object.freeze({ mp4: 'video/mp4', webm: 'video/webm' });
