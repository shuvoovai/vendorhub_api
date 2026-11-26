-- CreateEnum
CREATE TYPE "DealStatus" AS ENUM ('PENDING', 'APPROVED', 'REJECTED');

-- AlterTable
ALTER TABLE "FlashDeal" ADD COLUMN     "rejectReason" VARCHAR(300),
ADD COLUMN     "reviewedAt" TIMESTAMP(3),
ADD COLUMN     "reviewedById" TEXT,
ADD COLUMN     "status" "DealStatus" NOT NULL DEFAULT 'PENDING';

-- Deals that existed before the approval step were already live: keep them live (APPROVED).
-- New deals get the default PENDING.
UPDATE "FlashDeal" SET "status" = 'APPROVED';

-- CreateIndex
CREATE INDEX "FlashDeal_status_endsAt_idx" ON "FlashDeal"("status", "endsAt");

-- AddForeignKey
ALTER TABLE "FlashDeal" ADD CONSTRAINT "FlashDeal_reviewedById_fkey" FOREIGN KEY ("reviewedById") REFERENCES "User"("id") ON DELETE SET NULL ON UPDATE CASCADE;
