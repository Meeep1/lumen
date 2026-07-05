-- AlterTable
ALTER TABLE "User" ADD COLUMN     "appleUserId" TEXT,
ADD COLUMN     "notifyNewLike" BOOLEAN NOT NULL DEFAULT true,
ADD COLUMN     "notifyNewMatch" BOOLEAN NOT NULL DEFAULT true,
ADD COLUMN     "notifyNewMessage" BOOLEAN NOT NULL DEFAULT true,
ADD COLUMN     "pushPlatform" TEXT,
ADD COLUMN     "pushToken" TEXT,
ALTER COLUMN "passwordHash" DROP NOT NULL;

-- CreateIndex
CREATE UNIQUE INDEX "User_appleUserId_key" ON "User"("appleUserId");

