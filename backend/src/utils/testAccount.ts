import { PrismaClient } from '@prisma/client';

/** Same suffix `prisma/seed.ts` uses to tag every fake profile it creates — reusing it here
 * rather than a new schema flag, since it's already the established way to identify "not a
 * real account" rows. */
const SEED_EMAIL_SUFFIX = '+seed@lumen.test';

/**
 * Wipes a test account's profile back to a blank, pre-onboarding state on every login, so an
 * App Store reviewer always sees the real signup→onboarding→discovery flow rather than whatever
 * state a previous review session left behind.
 *
 * Deliberately does NOT delete incoming swipes (`swipedId = userId`) — those are the seed
 * profiles' pre-seeded "likes you" entries (see seed.ts), and leaving them intact means Likes You
 * has content immediately after onboarding instead of needing a location-dependent reseed.
 * Outgoing swipes/matches are the account's own actions and do get cleared, since "nothing added"
 * means no leftover matches/chat history either.
 */
export async function resetTestAccount(prisma: PrismaClient, userId: string): Promise<void> {
  await prisma.photo.deleteMany({ where: { userId } });
  await prisma.swipe.deleteMany({ where: { swiperId: userId } });
  await prisma.match.deleteMany({ where: { OR: [{ userAId: userId }, { userBId: userId }] } });
  await prisma.block.deleteMany({ where: { OR: [{ blockerId: userId }, { blockedId: userId }] } });
  await prisma.report.deleteMany({ where: { OR: [{ reporterId: userId }, { reportedId: userId }] } });

  await prisma.user.update({
    where: { id: userId },
    data: {
      bio: null, pronouns: null, styleTags: [], heightInches: null, jobTitle: null, school: null,
      prompt1Question: null, prompt1Answer: null, prompt2Question: null, prompt2Answer: null,
      latitude: null, longitude: null, cityDisplay: null,
      isVerified: false, verificationPhotoUrl: null, verificationStatus: 'none',
      verificationReviewedById: null, verificationReviewedAt: null,
      pushToken: null, pushPlatform: null,
      discoverable: true, isActive: true,
    },
  });
}

/**
 * Moves every seed profile to within ~1.5 miles of the given point. Called right after a test
 * account sets its location during onboarding (see PATCH /profile/me), since the account's
 * location is wiped on every reset and a reviewer could be testing from anywhere — pinning the
 * seed profiles to a fixed city would mean Discovery/Likes You come up empty for anyone reviewing
 * outside that radius.
 */
export async function relocateSeedProfilesNear(
  prisma: PrismaClient,
  lat: number,
  lon: number,
  city: string | null
): Promise<void> {
  const seedProfiles = await prisma.user.findMany({
    where: { email: { endsWith: SEED_EMAIL_SUFFIX } },
    select: { id: true },
  });

  for (const profile of seedProfiles) {
    const jitterLat = (Math.random() - 0.5) * 0.04; // ~±1.4mi
    const jitterLon = (Math.random() - 0.5) * 0.04;
    await prisma.user.update({
      where: { id: profile.id },
      data: { latitude: lat + jitterLat, longitude: lon + jitterLon, cityDisplay: city },
    });
  }
}
