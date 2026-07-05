// Creates the single account handed to App Store review as the "demo account" in App Store
// Connect's review notes. Unlike every other account, this one resets to a blank, pre-onboarding
// state on every real login (see resetTestAccount in src/utils/testAccount.ts, hooked into
// POST /auth/login) — a reviewer always sees the full signup→onboarding→discovery flow, never
// whatever state a previous review session left behind. It shares the existing seed profiles
// (prisma/seed.ts's `+seed@lumen.test` accounts) for Discovery/Likes You content, re-anchored to
// wherever this account's location ends up once onboarding sets it.
//
// Run with: npm run create-test-account -- <email> [password]
// Safe to re-run — upserts rather than failing if the email already exists.

import { PrismaClient } from '@prisma/client';
import crypto from 'crypto';
import { hashPassword } from '../src/utils/auth';

const prisma = new PrismaClient();

// Deliberately simple, not randomly generated — an Apple reviewer has to type this by hand into
// the app, and this account can never hold anything sensitive anyway (every real login wipes it
// back to blank, see resetTestAccount). Entropy just adds friction here for no real security
// benefit; pass a second argument to override it if you want something else.
const DEFAULT_PASSWORD = 'LumenReview2026';

async function main() {
  const args = process.argv.slice(2);
  const email = args[0];
  const password = args[1] || DEFAULT_PASSWORD;

  if (!email) {
    console.error('Usage: npm run create-test-account -- <email> [password]');
    process.exit(1);
  }

  const passwordHash = await hashPassword(password);

  const user = await prisma.user.upsert({
    where: { email },
    update: {
      passwordHash,
      isTestAccount: true,
      isActive: true,
      discoverable: true,
      emailVerified: true,
      femAttestationAccepted: true,
      // Blank slate — matches exactly what resetTestAccount produces, so the very first login
      // behaves identically to every login after it.
      bio: null, pronouns: null, styleTags: [], heightInches: null, jobTitle: null, school: null,
      prompt1Question: null, prompt1Answer: null, prompt2Question: null, prompt2Answer: null,
      latitude: null, longitude: null, cityDisplay: null,
      isVerified: false, verificationPhotoUrl: null, verificationStatus: 'none',
    },
    create: {
      email,
      phone: `+1000${crypto.randomInt(1000000, 9999999)}`,
      passwordHash,
      dateOfBirth: new Date('2000-01-01'),
      genderIdentity: 'woman',
      femAttestationAccepted: true,
      femAttestationAcceptedAt: new Date(),
      emailVerified: true,
      isTestAccount: true,
      isActive: true,
      discoverable: true,
    },
  });

  await prisma.photo.deleteMany({ where: { userId: user.id } });

  console.log(`Test/review account ready: ${user.email}`);
  console.log(`Password: ${password}`);
  console.log('Give these to App Store Connect as the demo account. Every real login through');
  console.log('this account resets it to a blank pre-onboarding state — see resetTestAccount.');
}

main()
  .catch((e) => {
    console.error(e);
    process.exit(1);
  })
  .finally(async () => {
    await prisma.$disconnect();
  });
