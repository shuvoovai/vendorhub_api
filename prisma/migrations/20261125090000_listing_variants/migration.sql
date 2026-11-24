-- DropIndex
DROP INDEX "CartItem_cartId_listingId_key";

-- AlterTable
ALTER TABLE "CartItem" ADD COLUMN     "variantId" TEXT;

-- AlterTable
ALTER TABLE "OrderItem" ADD COLUMN     "variantId" TEXT,
ADD COLUMN     "variantLabel" TEXT;

-- AlterTable
ALTER TABLE "ShopListing" ADD COLUMN     "variantOptions" JSONB NOT NULL DEFAULT '[]';

-- CreateTable
CREATE TABLE "ListingVariant" (
    "id" TEXT NOT NULL,
    "listingId" TEXT NOT NULL,
    "options" JSONB NOT NULL,
    "optionsKey" TEXT NOT NULL,
    "price" INTEGER,
    "stockQty" INTEGER,
    "isActive" BOOLEAN NOT NULL DEFAULT true,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "ListingVariant_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "ListingVariant_listingId_optionsKey_key" ON "ListingVariant"("listingId", "optionsKey");

-- CreateIndex
-- NULLS NOT DISTINCT: also only one variant-less line per (cart, listing)
CREATE UNIQUE INDEX "CartItem_cartId_listingId_variantId_key" ON "CartItem"("cartId", "listingId", "variantId") NULLS NOT DISTINCT;

-- AddForeignKey
ALTER TABLE "ListingVariant" ADD CONSTRAINT "ListingVariant_listingId_fkey" FOREIGN KEY ("listingId") REFERENCES "ShopListing"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "CartItem" ADD CONSTRAINT "CartItem_variantId_fkey" FOREIGN KEY ("variantId") REFERENCES "ListingVariant"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "OrderItem" ADD CONSTRAINT "OrderItem_variantId_fkey" FOREIGN KEY ("variantId") REFERENCES "ListingVariant"("id") ON DELETE SET NULL ON UPDATE CASCADE;

