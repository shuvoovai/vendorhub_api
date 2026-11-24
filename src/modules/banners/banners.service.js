import { prisma } from '../../lib/prisma.js';
import { AppError } from '../../lib/errors.js';
import { processImage } from '../../lib/images.js';
import { stageImage, removeImage, imageUrls, publishVideo, removeVideo } from '../../lib/storage.js';
import { detectVideo } from '../../lib/videos.js';

const PUBLIC_LIMIT = 5;
const NOT_FOUND = 'Banner not found';

// Only what the home page slider needs.
const presentPublic = (b) => ({
  id: b.id,
  imageUrl: imageUrls(b.imageKey).url,
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
  const { url, thumbUrl } = imageUrls(imageKey);
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

// Processes and publishes the photo; returns its key and a cleanup for when the database write fails.
async function publishPhoto(file) {
  const processed = await processImage(file.buffer, 'HOME_BANNER');
  const staged = await stageImage(processed);
  await staged.commit();
  return staged.key;
}

// Checks the real type from the first bytes before anything is written.
function videoType(video) {
  const ext = detectVideo(video.buffer);
  if (!ext) throw new AppError(400, 'The video must be an MP4 or WebM file');
  return ext;
}

export async function create(admin, input, file, video) {
  if (!file) throw new AppError(400, 'Send exactly one photo in the multipart field "image"');
  const ext = video ? videoType(video) : null;
  const key = await publishPhoto(file);
  let vid = null;
  try {
    if (ext) vid = await publishVideo(video.buffer, ext);
    const banner = await prisma.$transaction(async (tx) => {
      const sortOrder = input.sortOrder ?? (await tx.banner.count());
      const b = await tx.banner.create({
        data: { ...input, sortOrder, imageKey: key, ...(vid && { videoKey: vid.key, videoUrl: vid.url }) },
      });
      await audit(tx, admin.id, 'banner.created', b.id, { titleEn: b.titleEn, videoAdded: Boolean(vid) });
      return b;
    });
    return presentAdmin(banner);
  } catch (err) {
    await removeImage(key).catch(() => {});
    if (vid) await removeVideo(vid.key).catch(() => {});
    throw err;
  }
}

export async function update(admin, id, body, file, video) {
  const { removeVideo: dropVideo, ...input } = body;
  const current = await prisma.banner.findUnique({ where: { id } });
  if (!current) throw new AppError(404, NOT_FOUND);
  if (Object.keys(input).length === 0 && !file && !video && !dropVideo) throw new AppError(400, 'Nothing to update');
  if (video && dropVideo) throw new AppError(400, 'Send a new video or removeVideo, not both');
  const ext = video ? videoType(video) : null;

  const startsAt = input.startsAt !== undefined ? input.startsAt : current.startsAt;
  const endsAt = input.endsAt !== undefined ? input.endsAt : current.endsAt;
  if (startsAt && endsAt && endsAt <= startsAt) throw new AppError(400, 'endsAt must be after startsAt');

  const key = file ? await publishPhoto(file) : null;
  let vid = null;
  let banner;
  try {
    if (ext) vid = await publishVideo(video.buffer, ext);
    const videoData = vid ? { videoKey: vid.key, videoUrl: vid.url } : dropVideo ? { videoKey: null, videoUrl: null } : {};
    banner = await prisma.$transaction(async (tx) => {
      const b = await tx.banner.update({ where: { id }, data: { ...input, ...(key && { imageKey: key }), ...videoData } });
      await audit(tx, admin.id, 'banner.updated', id, {
        fields: Object.keys(input),
        imageReplaced: Boolean(key),
        videoAdded: Boolean(vid),
        videoRemoved: Boolean(current.videoKey && (vid || dropVideo)),
      });
      return b;
    });
  } catch (err) {
    if (key) await removeImage(key).catch(() => {});
    if (vid) await removeVideo(vid.key).catch(() => {});
    throw err;
  }
  // old files, after success
  if (key) await removeImage(current.imageKey).catch(() => {});
  if ((vid || dropVideo) && current.videoKey) await removeVideo(current.videoKey).catch(() => {});
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
    prisma.auditLog.create({ data: { actorId: admin.id, action: 'banner.deleted', entityType: 'Banner', entityId: id, meta: { titleEn: banner.titleEn } } }),
  ]);
  await removeImage(banner.imageKey).catch(() => {});
  await removeVideo(banner.videoKey).catch(() => {});
}
