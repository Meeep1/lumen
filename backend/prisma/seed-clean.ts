// Removes the test profiles created by seed.ts (matched by the "+seed@lumen.test" email
// pattern). Cascading deletes on the User relations clean up their photos/swipes/etc.

import { PrismaClient } from '@prisma/client';

const prisma = new PrismaClient();

async function main() {
  const { count } = await prisma.user.deleteMany({
    where: { email: { endsWith: '+seed@lumen.test' } },
  });
  console.log(`Removed ${count} seeded test profile(s).`);
}

main()
  .catch((e) => {
    console.error(e);
    process.exit(1);
  })
  .finally(async () => {
    await prisma.$disconnect();
  });
