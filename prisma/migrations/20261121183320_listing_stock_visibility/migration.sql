-- CreateEnum
CREATE TYPE "StockVisibility" AS ENUM ('PUBLIC', 'VENDORS', 'HIDDEN');

-- AlterTable
ALTER TABLE "ShopListing" ADD COLUMN     "stockVisibility" "StockVisibility" NOT NULL DEFAULT 'HIDDEN';
