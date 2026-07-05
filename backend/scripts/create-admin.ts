// Bootstraps the very first admin account directly in the database, bypassing the API — there's
// a chicken-and-egg problem otherwise: routes/admin-auth.ts's POST /admin-auth/team (which is how
// every admin after the first one gets created) requires an existing super admin to call it.
// Every admin created this way is a super admin, since nobody else exists yet to grant them a
// narrower set of permissions — use the admin site's Team tab afterward to invite the rest of the
// team with whatever specific permissions they actually need.
//
// Run with: npm run create-admin -- admin@example.com [password]
// Safe to re-run against an existing email — resets the password and re-confirms super admin
// rather than failing.

import { PrismaClient } from '@prisma/client';
import crypto from 'crypto';
import { hashPassword } from '../src/utils/auth';

const prisma = new PrismaClient();

async function main() {
  const args = process.argv.slice(2);
  const email = args[0];
  const password = args[1] || crypto.randomBytes(12).toString('base64url');

  if (!email) {
    console.error('Usage: npm run create-admin -- <email> [password]');
    process.exit(1);
  }

  const passwordHash = await hashPassword(password);

  const admin = await prisma.adminUser.upsert({
    where: { email },
    update: {
      passwordHash,
      isSuperAdmin: true,
      isActive: true,
    },
    create: {
      email,
      passwordHash,
      isSuperAdmin: true,
      // Left empty deliberately — isSuperAdmin already bypasses the permissions check entirely
      // (see requirePermission in middleware/adminAuth.ts), so populating this would just be a
      // second, potentially stale source of truth for "this admin can do everything."
      permissions: [],
    },
  });

  console.log(`Admin account ready: ${admin.email} (super admin)`);
  console.log(`Password: ${password}`);
  console.log('Sign in at /admin/ with these — save the password now, it is not stored anywhere retrievable.');
}

main()
  .catch((e) => {
    console.error(e);
    process.exit(1);
  })
  .finally(async () => {
    await prisma.$disconnect();
  });
