-- Vendor subscriptions (FREE / PRO). The plan is computed on read: PRO while Shop.proUntil > now().
-- Existing shops get proUntil NULL = FREE; their listings stay, they just cannot add more over the limit.

-- CreateEnum
CREATE TYPE "SubscriptionMethod" AS ENUM ('BKASH', 'NAGAD');

-- CreateEnum
CREATE TYPE "SubscriptionRequestStatus" AS ENUM ('PENDING', 'APPROVED', 'REJECTED');

-- AlterTable
ALTER TABLE "Shop" ADD COLUMN     "proUntil" TIMESTAMP(3);

-- CreateTable
CREATE TABLE "SubscriptionRequest" (
    "id" TEXT NOT NULL,
    "shopId" TEXT NOT NULL,
    "plan" TEXT NOT NULL DEFAULT 'PRO',
    "months" INTEGER NOT NULL,
    "amount" INTEGER NOT NULL,
    "method" "SubscriptionMethod" NOT NULL,
    "walletNumber" VARCHAR(11) NOT NULL,
    "transactionId" VARCHAR(12) NOT NULL,
    "status" "SubscriptionRequestStatus" NOT NULL DEFAULT 'PENDING',
    "rejectReason" VARCHAR(300),
    "requestedById" TEXT NOT NULL,
    "reviewedById" TEXT,
    "reviewedAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "SubscriptionRequest_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "SubscriptionRequest_transactionId_key" ON "SubscriptionRequest"("transactionId");

-- CreateIndex
CREATE INDEX "SubscriptionRequest_shopId_status_idx" ON "SubscriptionRequest"("shopId", "status");

-- CreateIndex
CREATE INDEX "SubscriptionRequest_status_createdAt_idx" ON "SubscriptionRequest"("status", "createdAt");

-- AddForeignKey
ALTER TABLE "SubscriptionRequest" ADD CONSTRAINT "SubscriptionRequest_shopId_fkey" FOREIGN KEY ("shopId") REFERENCES "Shop"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "SubscriptionRequest" ADD CONSTRAINT "SubscriptionRequest_requestedById_fkey" FOREIGN KEY ("requestedById") REFERENCES "User"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "SubscriptionRequest" ADD CONSTRAINT "SubscriptionRequest_reviewedById_fkey" FOREIGN KEY ("reviewedById") REFERENCES "User"("id") ON DELETE SET NULL ON UPDATE CASCADE;

