-- CreateEnum
CREATE TYPE "ToletInquiryTime" AS ENUM ('MORNING', 'AFTERNOON', 'EVENING');

-- CreateEnum
CREATE TYPE "ToletInquiryStatus" AS ENUM ('NEW', 'CONTACTED', 'CLOSED');

-- CreateTable
CREATE TABLE "ToletInquiry" (
    "id" TEXT NOT NULL,
    "toletId" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "phone" TEXT NOT NULL,
    "preferredDate" DATE NOT NULL,
    "preferredTime" "ToletInquiryTime" NOT NULL,
    "message" TEXT,
    "status" "ToletInquiryStatus" NOT NULL DEFAULT 'NEW',
    "submitterIpHash" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "ToletInquiry_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "ToletInquiry_status_createdAt_idx" ON "ToletInquiry"("status", "createdAt");

-- CreateIndex
CREATE INDEX "ToletInquiry_submitterIpHash_createdAt_idx" ON "ToletInquiry"("submitterIpHash", "createdAt");

-- CreateIndex
CREATE INDEX "ToletInquiry_toletId_idx" ON "ToletInquiry"("toletId");

-- AddForeignKey
ALTER TABLE "ToletInquiry" ADD CONSTRAINT "ToletInquiry_toletId_fkey" FOREIGN KEY ("toletId") REFERENCES "Tolet"("id") ON DELETE CASCADE ON UPDATE CASCADE;
