// Grants (or revokes with --revoke) admin access to an existing account by email.
// Run with: npm run make-admin -- someone@example.com
//           npm run make-admin -- someone@example.com --revoke

import { PrismaClient } from '@prisma/client';

const prisma = new PrismaClient();

async function main() {
  const args = process.argv.slice(2);
  const email = args.find((a) => !a.startsWith('--'));
  const revoke = args.includes('--revoke');

  if (!email) {
    console.error('Usage: npm run make-admin -- <email> [--revoke]');
    process.exit(1);
  }

  const user = await prisma.user.update({
    where: { email },
    data: { isAdmin: !revoke },
  });

  console.log(`${user.email} isAdmin = ${user.isAdmin}`);
}

main()
  .catch((e) => {
    console.error(e);
    process.exit(1);
  })
  .finally(async () => {
    await prisma.$disconnect();
  });
