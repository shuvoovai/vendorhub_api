-- AlterTable
ALTER TABLE "Banner" ADD COLUMN     "videoKey" TEXT,
ADD COLUMN     "videoUrl" TEXT;

-- CreateIndex
CREATE UNIQUE INDEX "Banner_videoKey_key" ON "Banner"("videoKey");

