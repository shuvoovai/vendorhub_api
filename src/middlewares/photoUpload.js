// Receives exactly ONE photo in a multipart field: max 5 MB, almost nothing else.
// Shared by every photo endpoint, so all of them follow the same rules.
import multer from 'multer';
import { AppError } from '../lib/errors.js';

const photo = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: 5 * 1024 * 1024, files: 1, fields: 5, fieldSize: 1024, parts: 6 },
});

export function receiveFileField(field) {
  return function receive(req, res, next) {
    photo.single(field)(req, res, (err) => {
      if (!err) return next();
      if (err.code === 'LIMIT_FILE_SIZE') return next(new AppError(413, 'The photo is larger than 5 MB'));
      if (err.name === 'MulterError') return next(new AppError(400, `Send exactly one photo in the multipart field "${field}"`));
      return next(err);
    });
  };
}

// markets, products, shop logo and banner
export const receivePhoto = receiveFileField('image');

// Home page banners: one photo in "image" (max 3 MB), one optional video in "video" (MP4/WebM, max 20 MB),
// plus up to 13 short text fields. These two routes are the only ones allowed about 25 MB per request.
const IMAGE_MAX = 3 * 1024 * 1024;
const VIDEO_MAX = 20 * 1024 * 1024;
const BANNER_REQUEST_MAX = 25 * 1024 * 1024;
const bannerUpload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: VIDEO_MAX, files: 2, fields: 13, fieldSize: 1024, parts: 15 },
});
const bannerFields = bannerUpload.fields([
  { name: 'image', maxCount: 1 },
  { name: 'video', maxCount: 1 },
]);
const tooLarge = (field) => new AppError(413, field === 'video' ? 'The video is larger than 20 MB' : 'The photo is larger than 3 MB');

// Sets req.file (the photo) and req.video (the video).
export function receiveBannerForm(req, res, next) {
  if (Number(req.headers['content-length']) > BANNER_REQUEST_MAX) return next(new AppError(413, 'The upload is larger than 25 MB'));
  bannerFields(req, res, (err) => {
    if (err) {
      if (err.code === 'LIMIT_FILE_SIZE') return next(tooLarge(err.field));
      if (err.name === 'MulterError') return next(new AppError(400, 'Send at most one photo in "image" and one video in "video"'));
      return next(err);
    }
    req.file = req.files?.image?.[0];
    req.video = req.files?.video?.[0];
    delete req.files;
    if (req.file && req.file.size > IMAGE_MAX) return next(tooLarge('image'));
    next();
  });
}
