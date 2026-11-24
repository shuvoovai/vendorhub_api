-- AlterTable
ALTER TABLE "Cart" ADD COLUMN     "guestTokenHash" TEXT,
ADD COLUMN     "lastUsedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
ALTER COLUMN "userId" DROP NOT NULL;

-- CreateIndex
CREATE UNIQUE INDEX "Cart_guestTokenHash_key" ON "Cart"("guestTokenHash");

-- CreateIndex
CREATE INDEX "Cart_lastUsedAt_idx" ON "Cart"("lastUsedAt");


-- A cart belongs to exactly one of: a user, or a guest token.
ALTER TABLE "Cart" ADD CONSTRAINT "Cart_owner_check" CHECK (("userId" IS NULL) <> ("guestTokenHash" IS NULL));
