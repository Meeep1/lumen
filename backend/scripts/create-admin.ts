// Creates a standalone admin account — not a real dating profile. Reuses the same User table
// and login flow (email/password -> /auth/login) as everything else, since that's already the
// tested/hardened path (see requireAdmin in middleware/auth.ts), but isActive/discoverable are
// both forced to false so this account can never surface anywhere in the app itself (discovery,
// other users' profile views) — it exists purely to sign into the admin site at /admin/.
//
// Run with: npm run create-admin -- admin@example.com [password]
// If that email already exists, this just resets its password and (re)promotes it to admin
// instead of failing — safe to re-run.

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

  const user = await prisma.user.upsert({
    where: { email },
    update: {
      passwordHash,
      isAdmin: true,
      isActive: false,
      discoverable: false,
      emailVerified: true,
    },
    create: {
      email,
      // Unique placeholder — this account never receives a real phone call/OTP, the field just
      // exists because User.phone is required by the schema for every row.
      phone: `+1000${crypto.randomInt(1000000, 9999999)}`,
      passwordHash,
      dateOfBirth: new Date('1990-01-01'),
      genderIdentity: 'other',
      femAttestationAccepted: true,
      femAttestationAcceptedAt: new Date(),
      emailVerified: true,
      isAdmin: true,
      isActive: false,
      discoverable: false,
    },
  });

  console.log(`Admin account ready: ${user.email}`);
  console.log(`Password: ${password}`);
  console.log('Sign in at /admin/ (or POST /auth/login) with these — save the password now, it is not stored anywhere retrievable.');
}

main()
  .catch((e) => {
    console.error(e);
    process.exit(1);
  })
  .finally(async () => {
    await prisma.$disconnect();
  });
