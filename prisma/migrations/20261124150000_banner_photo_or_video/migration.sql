-- AlterTable
ALTER TABLE "Banner" ALTER COLUMN "imageKey" DROP NOT NULL;


-- A banner is now a photo OR a video. Banners made earlier with both keep the photo.
UPDATE "Banner" SET "videoKey" = NULL, "videoUrl" = NULL WHERE "imageKey" IS NOT NULL AND "videoKey" IS NOT NULL;
