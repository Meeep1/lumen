import { prisma } from '../../src/server';

/// Wipes every table between tests so one test's data can't leak into another's assertions.
/// Order matters — children before parents, even though the schema's onDelete: Cascade would
/// handle most of this via a User delete alone; being explicit here doesn't depend on that
/// staying true and reads clearly as "full reset" rather than relying on cascade side effects.
export async function cleanDb(): Promise<void> {
  await prisma.message.deleteMany();
  await prisma.match.deleteMany();
  await prisma.swipe.deleteMany();
  await prisma.block.deleteMany();
  await prisma.report.deleteMany();
  await prisma.photo.deleteMany();
  await prisma.refreshToken.deleteMany();
  await prisma.user.deleteMany();
}
