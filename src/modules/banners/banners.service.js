import { prisma } from '../../lib/prisma.js';
import { AppError } from '../../lib/errors.js';
import { processImage } from '../../lib/images.js';
import { stageImage, removeImage, imageUrls, publishVideo, removeVideo } from '../../lib/storage.js';
import { detectVideo } from '../../lib/videos.js';

const PUBLIC_LIMIT = 5;
const NOT_FOUND = 'Banner not found';
const ONE_FILE = 'Send exactly one file: a photo in "image" or a video in "video"';

// A banner is a photo (imageKey) OR a video (videoKey + videoUrl), never both, never neither.
const mediaType = (b) => (b.videoKey ? 'video' : 'image');
const photoUrls = (b) => (b.imageKey ? imageUrls(b.imageKey) : { url: null, thumbUrl: null });

// Only what the home page slider needs.
const presentPublic = (b) => ({
  id: b.id,
  imageUrl: photoUrls(b).url,
  videoUrl: b.videoUrl ?? null,
  titleEn: b.titleEn,
  titleBn: b.titleBn,
  textEn: b.textEn,
  textBn: b.textBn,
  ctaEn: b.ctaEn,
  ctaBn: b.ctaBn,
  href: b.href,
});

const presentAdmin = (b) => {
  const { imageKey, videoKey, ...rest } = b;
  const { url, thumbUrl } = photoUrls(b);
  return { ...rest, imageUrl: url, thumbUrl, videoUrl: b.videoUrl ?? null };
};

const audit = (tx, actorId, action, entityId, meta) =>
  tx.auditLog.create({ data: { actorId, action, entityType: 'Banner', entityId, meta } });

export async function listPublic() {
  const now = new Date();
  const rows = await prisma.banner.findMany({
    where: {
      isActive: true,
      AND: [{ OR: [{ startsAt: null }, { startsAt: { lte: now } }] }, { OR: [{ endsAt: null }, { endsAt: { gt: now } }] }],
    },
    orderBy: [{ sortOrder: 'asc' }, { createdAt: 'asc' }],
    take: PUBLIC_LIMIT,
  });
  return rows.map(presentPublic);
}

export async function listAll() {
  const rows = await prisma.banner.findMany({ orderBy: [{ sortOrder: 'asc' }, { createdAt: 'asc' }] });
  return rows.map(presentAdmin);
}

// Checks (video: real type from the first bytes) and publishes the one file.
// Returns the columns to set (the other kind is cleared) and a cleanup for when the database write fails.
async function publishMedia(file, video) {
  if (video) {
    const ext = detectVideo(video.buffer);
    if (!ext) throw new AppError(400, 'The video must be an MP4 or WebM file');
    const { key, url } = await publishVideo(video.buffer, ext);
    return { type: 'video', data: { videoKey: key, videoUrl: url, imageKey: null }, undo: () => removeVideo(key) };
  }
  const processed = await processImage(file.buffer, 'HOME_BANNER');
  const staged = await stageImage(processed);
  await staged.commit();
  return { type: 'image', data: { imageKey: staged.key, videoKey: null, videoUrl: null }, undo: () => removeImage(staged.key) };
}

// Deletes the files of a banner's old media (after the database already points elsewhere).
const removeMediaFiles = (b) => Promise.all([removeImage(b.imageKey).catch(() => {}), removeVideo(b.videoKey).catch(() => {})]);

export async function create(admin, input, file, video) {
  if (Boolean(file) === Boolean(video)) throw new AppError(400, ONE_FILE);
  const media = await publishMedia(file, video);
  try {
    const banner = await prisma.$transaction(async (tx) => {
      const sortOrder = input.sortOrder ?? (await tx.banner.count());
      const b = await tx.banner.create({ data: { ...input, sortOrder, ...media.data } });
      await audit(tx, admin.id, 'banner.created', b.id, { titleEn: b.titleEn, mediaType: media.type });
      return b;
    });
    return presentAdmin(banner);
  } catch (err) {
    await media.undo().catch(() => {});
    throw err;
  }
}

export async function update(admin, id, input, file, video) {
  if (file && video) throw new AppError(400, ONE_FILE);
  const current = await prisma.banner.findUnique({ where: { id } });
  if (!current) throw new AppError(404, NOT_FOUND);
  if (Object.keys(input).length === 0 && !file && !video) throw new AppError(400, 'Nothing to update');

  const startsAt = input.startsAt !== undefined ? input.startsAt : current.startsAt;
  const endsAt = input.endsAt !== undefined ? input.endsAt : current.endsAt;
  if (startsAt && endsAt && endsAt <= startsAt) throw new AppError(400, 'endsAt must be after startsAt');

  const media = file || video ? await publishMedia(file, video) : null;
  let banner;
  try {
    banner = await prisma.$transaction(async (tx) => {
      const b = await tx.banner.update({ where: { id }, data: { ...input, ...media?.data } });
      await audit(tx, admin.id, 'banner.updated', id, {
        fields: Object.keys(input),
        mediaType: mediaType(b),
        mediaReplaced: Boolean(media),
        ...(media && { previousMediaType: mediaType(current) }),
      });
      return b;
    });
  } catch (err) {
    if (media) await media.undo().catch(() => {});
    throw err;
  }
  if (media) await removeMediaFiles(current); // old files, after success
  return presentAdmin(banner);
}

// The list must name every banner exactly once; its order becomes sortOrder 0, 1, 2, ...
export async function reorder(admin, ids) {
  const all = await prisma.banner.findMany({ select: { id: true } });
  const known = new Set(all.map((b) => b.id));
  if (ids.length !== known.size || !ids.every((i) => known.has(i))) {
    throw new AppError(400, 'The list must contain every banner exactly once');
  }
  await prisma.$transaction([
    ...ids.map((bid, i) => prisma.banner.update({ where: { id: bid }, data: { sortOrder: i } })),
    prisma.auditLog.create({ data: { actorId: admin.id, action: 'banner.reordered', entityType: 'Banner', entityId: ids[0], meta: { ids } } }),
  ]);
  return listAll();
}

export async function remove(admin, id) {
  const banner = await prisma.banner.findUnique({ where: { id } });
  if (!banner) throw new AppError(404, NOT_FOUND);
  await prisma.$transaction([
    prisma.banner.delete({ where: { id } }),
    prisma.auditLog.create({
      data: { actorId: admin.id, action: 'banner.deleted', entityType: 'Banner', entityId: id, meta: { titleEn: banner.titleEn, mediaType: mediaType(banner) } },
    }),
  ]);
  await removeMediaFiles(banner);
}
