-- AlterEnum
ALTER TYPE "PaymentMethod" ADD VALUE 'NAGAD';

-- AlterTable
ALTER TABLE "Payment" ADD COLUMN     "transactionId" VARCHAR(12),
ADD COLUMN     "walletNumber" VARCHAR(11);
