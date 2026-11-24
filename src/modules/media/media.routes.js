// Serves processed public images (markets, shop photos, avatars, product images) and banner videos.
//
// Videos (<uuid>.mp4 / <uuid>.webm) get video/mp4 or video/webm and support Range requests
// ("Accept-Ranges: bytes", 206 answers), which Safari needs to play them.
// Only server-made names can be served: "<uuid>.webp" and "<uuid>-thumb.webp" from the media folder.
// Any other name (another extension, "../", encoded slashes) is a 404 before the disk is touched.
// The headers make the browser treat the answer strictly as an image:
//   - Content-Type image/webp, and nosniff: never guessed as HTML or script
//   - Content-Security-Policy "default-src 'none'; sandbox": even opened directly, nothing can run
//   - Content-Disposition inline: shown, not downloaded
//   - Cross-Origin-Resource-Policy same-site: our website (and its app wrappers) may embed it, other sites may not
//   - cached for a year, immutable: the name changes whenever a photo changes
import path from 'node:path';
import { Router } from 'express';
import { mediaFilePath } from '../../lib/storage.js';
import { AppError } from '../../lib/errors.js';

const router = Router();

const TYPES = Object.freeze({ '.webp': 'image/webp', '.mp4': 'video/mp4', '.webm': 'video/webm' });
const BASE_HEADERS = Object.freeze({
  'X-Content-Type-Options': 'nosniff',
  'Content-Disposition': 'inline',
  'Content-Security-Policy': "default-src 'none'; sandbox",
  'Cross-Origin-Resource-Policy': 'same-site',
});

router.get('/media/:name', (req, res, next) => {
  const file = mediaFilePath(req.params.name);
  if (!file) return next(new AppError(404, 'Not found'));

  const type = TYPES[path.extname(file)];
  const headers = { ...BASE_HEADERS, 'Content-Type': type, ...(type !== 'image/webp' && { 'Accept-Ranges': 'bytes' }) };
  res.sendFile(file, { headers, acceptRanges: true, maxAge: '365d', immutable: true, dotfiles: 'deny' }, (err) => {
    if (!err || res.headersSent) return; // sent, or the client went away mid-transfer
    if (err.status === 416) return res.status(416).end(); // Range outside the file ("Content-Range: bytes */size" is set)
    next(err.code === 'ENOENT' || err.status === 404 ? new AppError(404, 'Not found') : err);
  });
});

export default router;