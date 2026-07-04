-- AlterTable
ALTER TABLE "Photo" ADD COLUMN     "moderationLabels" TEXT[] DEFAULT ARRAY[]::TEXT[];
