// Temporary local test data — NOT for production. Creates a set of fake profiles with
// generated placeholder avatars (no real people's photos) so discovery/swipe/match/chat
// can be exercised end-to-end without manually signing up a dozen accounts.
//
// Run with: npm run seed          (creates/refreshes the test profiles)
//           npm run seed:clean    (removes just the test profiles)

import { PrismaClient } from '@prisma/client';
import fs from 'fs';
import path from 'path';
import { hashPassword } from '../src/utils/auth';
import { uploadPhoto } from '../src/utils/storage';

const prisma = new PrismaClient();

const TEST_PASSWORD = 'TestPass123!';
const SEED_TAG = '+seed'; // marks emails so cleanup can find them unambiguously

// Default fallback (New York City) if there's no real account to anchor to yet.
const FALLBACK_LAT = 40.7128;
const FALLBACK_LON = -74.006;
const FALLBACK_CITY = 'New York, NY';

/** Anchors seeded profiles near whoever's actually testing, not a hardcoded city — discovery's
 * default 50-mile radius means seeded profiles are invisible unless they're near the real
 * account's real GPS location. Also returns the real user's id so seeded profiles can pre-like
 * them (see main()) — swiping right on any of them then instantly creates a match to test
 * matching/chat without having to round-trip real swipes first. */
async function resolveRealUser(): Promise<{ id: string | null; lat: number; lon: number; city: string }> {
  const realUser = await prisma.user.findFirst({
    where: {
      email: { not: { endsWith: `${SEED_TAG}@lumen.test` } },
      latitude: { not: null },
      longitude: { not: null },
    },
    orderBy: { createdAt: 'desc' },
    select: { id: true, latitude: true, longitude: true, cityDisplay: true },
  });

  if (realUser?.latitude != null && realUser?.longitude != null) {
    return { id: realUser.id, lat: realUser.latitude, lon: realUser.longitude, city: realUser.cityDisplay ?? 'Nearby' };
  }
  return { id: null, lat: FALLBACK_LAT, lon: FALLBACK_LON, city: FALLBACK_CITY };
}

interface SeedProfile {
  handle: string;
  name: string;
  genderIdentity: 'woman' | 'femboy' | 'trans_woman' | 'nonbinary_feminine' | 'other';
  genderIdentityOther?: string;
  pronouns: string;
  bio: string;
  styleTags: string[];
  age: number;
  isVerified: boolean;
  heightInches: number;
  jobTitle: string;
  school?: string;
  prompt1Question: string;
  prompt1Answer: string;
  latJitter: number;
  lonJitter: number;
  /** Optional comment attached to this profile's pre-seeded like on your real account — gives
   * the Likes You screen some variety (some likes have a note, some don't) to test against. */
  likeMessage?: string;
  /** Which seed-assets photo set to use, if different from `handle` — lets procedurally
   * generated profiles reuse the 9 real photo sets round-robin instead of needing one asset
   * set per profile. */
  photoHandle?: string;
}

const PROFILES: SeedProfile[] = [
  { handle: 'mia', name: 'Mia', genderIdentity: 'woman', pronouns: 'she/her',
    bio: 'Coffee snob, plant mom, will talk your ear off about my cat.',
    styleTags: ['cottagecore', 'cozy', 'plant mom'], age: 26, isVerified: true,
    heightInches: 65, jobTitle: 'Barista', school: 'Portland State',
    prompt1Question: 'A random fact I love is...', prompt1Answer: 'Octopi have three hearts.',
    latJitter: 0.01, lonJitter: -0.02, likeMessage: 'Your plant collection looks incredible!' },
  { handle: 'kenji', name: 'Kenji', genderIdentity: 'femboy', pronouns: 'he/they',
    bio: 'Rhythm game enjoyer. Will absolutely lose to me at Tetris.',
    styleTags: ['gamer girl', 'y2k', 'streetwear'], age: 24, isVerified: false,
    heightInches: 68, jobTitle: 'QA Tester',
    prompt1Question: 'My ideal Sunday...', prompt1Answer: 'Arcade until my hands hurt.',
    latJitter: -0.03, lonJitter: 0.015 },
  { handle: 'sasha', name: 'Sasha', genderIdentity: 'trans_woman', pronouns: 'she/her',
    bio: 'Photographer. I will make you pose for way too many pictures.',
    styleTags: ['soft goth', 'artsy', 'alt'], age: 29, isVerified: true,
    heightInches: 70, jobTitle: 'Freelance Photographer', school: 'RISD',
    prompt1Question: 'The way to win me over is...', prompt1Answer: 'Let me art-direct our first photo together.',
    latJitter: 0.04, lonJitter: 0.03, likeMessage: 'Okay but your prompt answer is extremely real' },
  { handle: 'river', name: 'River', genderIdentity: 'nonbinary_feminine', pronouns: 'they/them',
    bio: 'Runs, climbs, occasionally falls off things. Looking for a belay partner.',
    styleTags: ['sporty', 'outdoorsy'], age: 27, isVerified: false,
    heightInches: 66, jobTitle: 'Physical Therapist',
    prompt1Question: "I'm weirdly competitive about...", prompt1Answer: 'Parallel parking.',
    latJitter: -0.015, lonJitter: -0.04 },
  { handle: 'dahlia', name: 'Dahlia', genderIdentity: 'woman', pronouns: 'she/her',
    bio: 'Cottagecore in theory, takeout in practice.',
    styleTags: ['cottagecore', 'cozy'], age: 31, isVerified: false,
    heightInches: 63, jobTitle: 'Elementary School Teacher', school: 'UMass Amherst',
    prompt1Question: 'Two truths and a lie...', prompt1Answer: "I've been to 12 countries, I hate cilantro, I once won a pie-eating contest.",
    latJitter: 0.02, lonJitter: 0.05 },
  { handle: 'quinn', name: 'Quinn', genderIdentity: 'nonbinary_feminine', pronouns: 'they/she',
    bio: 'DJ on weekends, extremely tired on weekdays.',
    styleTags: ['y2k', 'nightlife', 'alt'], age: 25, isVerified: false,
    heightInches: 69, jobTitle: 'DJ / Sound Engineer',
    prompt1Question: 'My love language is...', prompt1Answer: 'Sending you a playlist at 2am.',
    latJitter: -0.05, lonJitter: 0.01, likeMessage: 'We have to talk about music taste' },
  { handle: 'noa', name: 'Noa', genderIdentity: 'other', genderIdentityOther: 'Genderfluid',
    pronouns: 'she/they',
    bio: 'Currently reading four books at once and finishing none of them.',
    styleTags: ['cozy', 'artsy', 'bookish'], age: 23, isVerified: false,
    heightInches: 64, jobTitle: 'Grad Student', school: 'Bowdoin College',
    prompt1Question: 'A random fact I love is...', prompt1Answer: 'Wombats poop cubes.',
    latJitter: 0.03, lonJitter: -0.01 },
  { handle: 'wren', name: 'Wren', genderIdentity: 'femboy', pronouns: 'he/him',
    bio: 'Skateboarding badly since 2015. Ask me about my playlist.',
    styleTags: ['streetwear', 'alt', 'gamer girl'], age: 22, isVerified: true,
    heightInches: 67, jobTitle: 'Barista',
    prompt1Question: 'My ideal Sunday...', prompt1Answer: 'Skating until I eat pavement, then tacos.',
    latJitter: -0.02, lonJitter: -0.03 },
  { handle: 'iris', name: 'Iris', genderIdentity: 'trans_woman', pronouns: 'she/her',
    bio: 'Baker. I will absolutely try to feed you within ten minutes of meeting.',
    styleTags: ['cottagecore', 'cozy', 'bookish'], age: 30, isVerified: false,
    heightInches: 62, jobTitle: 'Pastry Chef', school: 'Culinary Institute of America',
    prompt1Question: 'The way to win me over is...', prompt1Answer: 'Compliment my sourdough starter unprompted.',
    latJitter: 0.015, lonJitter: 0.02, likeMessage: 'Consider your sourdough starter complimented' },
];

function dateOfBirthForAge(age: number): Date {
  const d = new Date();
  d.setFullYear(d.getFullYear() - age, 5, 15); // arbitrary mid-year birthday
  return d;
}

// --- Procedural bulk profiles -----------------------------------------------------------
// The 9 hand-written profiles above are enough to test matching/chat, but not enough to test
// scrolling behavior (discovery caps at 20/page, Likes You shows everyone at once) — a handful
// of cards doesn't surface pagination bugs or layout issues that only show up with volume. This
// generates a large batch of additional profiles instead, reusing the 9 real photo sets
// round-robin (no new photo assets needed) so discovery/likes-you have enough to meaningfully
// scroll through. Seeded RNG keeps output stable across re-runs rather than reshuffling every
// time.
const PHOTO_HANDLES = ['mia', 'kenji', 'sasha', 'river', 'dahlia', 'quinn', 'noa', 'wren', 'iris'];
const PROCEDURAL_COUNT = 60;

function mulberry32(seed: number) {
  let a = seed;
  return () => {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const JOBS = [
  'Nurse', 'Software Engineer', 'Yoga Instructor', 'Graphic Designer', 'Veterinarian', 'Chef',
  'Librarian', 'Marketing Manager', 'Personal Trainer', 'Architect', 'Florist', 'Social Worker',
  'Accountant', 'Musician', 'Real Estate Agent', 'Dental Hygienist', 'Interior Designer',
  'Journalist', 'Physical Therapist', 'Data Analyst', 'Copywriter', 'Massage Therapist',
];
const SCHOOLS = ['NYU', 'UC Berkeley', 'University of Michigan', 'Ohio State', 'Boston University', 'Emory University', 'University of Texas', undefined, undefined, undefined];
const BIOS = [
  "Perpetually cold, perpetually caffeinated.",
  "Will beat you at board games and gloat about it.",
  "Looking for someone to split a dessert with, not fight over it.",
  "My dog has more Instagram followers than I do.",
  "Professional overpacker for weekend trips.",
  "I peaked at karaoke in college and I'm at peace with that.",
  "Currently obsessed with a hobby I'll probably drop in a month.",
  "Ask me about the three houseplants I've somehow kept alive.",
  "Overly competitive about mini golf specifically.",
  "I will 100% fall asleep during the movie.",
  "Collector of tote bags I don't need.",
  "Convinced I have good taste in music, open to being wrong.",
  "Will send you fifteen photos of the same sunset.",
  "My love language is sending memes at 1am.",
  "Somehow always the one organizing the group trip.",
];
const TAGS_POOL = ['cottagecore', 'cozy', 'plant mom', 'gamer girl', 'y2k', 'streetwear', 'soft goth', 'artsy', 'alt', 'sporty', 'outdoorsy', 'nightlife', 'bookish'];
const FIRST_NAMES = [
  'Ava', 'Sofia', 'Luna', 'Zoe', 'Maya', 'Ruby', 'Nora', 'Piper', 'Hazel', 'Vera',
  'Skylar', 'Reese', 'Rowan', 'Emerson', 'Sage', 'Jules', 'Remy', 'Alex', 'Charlie', 'Devon',
  'Kai', 'Ari', 'Tatum', 'Blair', 'Finley', 'Marley', 'Wren', 'Indigo', 'Juniper', 'Lennon',
];
const GENDERS: SeedProfile['genderIdentity'][] = ['woman', 'femboy', 'trans_woman', 'nonbinary_feminine', 'other'];
const PRONOUNS_BY_GENDER: Record<string, string[]> = {
  woman: ['she/her'],
  femboy: ['he/they', 'he/him'],
  trans_woman: ['she/her'],
  nonbinary_feminine: ['they/them', 'they/she'],
  other: ['she/they', 'they/them'],
};
const PROMPTS: { question: string; answers: string[] }[] = [
  { question: 'A random fact I love is...', answers: ['Honey never spoils.', 'Sea otters hold hands while sleeping.', 'Bananas are berries but strawberries aren’t.'] },
  { question: 'My ideal Sunday...', answers: ['Farmers market, then doing absolutely nothing.', 'Long walk, longer nap.', 'Cooking a way-too-ambitious brunch.'] },
  { question: 'The way to win me over is...', answers: ['Remember the small stuff I mention once.', 'Make me laugh until it’s embarrassing.', 'Bring snacks. Always bring snacks.'] },
  { question: "I'm weirdly competitive about...", answers: ['Trivia night.', 'Finding parking.', 'Who packs lighter for trips.'] },
  { question: 'Two truths and a lie...', answers: ["I've run a marathon, I hate coffee, I've met a celebrity.", "I can't swim, I've lived in 3 countries, I'm afraid of birds."] },
  { question: 'My love language is...', answers: ['Leftovers I saved for you.', 'Sending you a playlist unprompted.', 'Remembering how you take your coffee.'] },
];
const LIKE_MESSAGES = [
  'Your prompt answer made me laugh out loud',
  'Okay we need to talk music taste',
  'Your energy in these photos is unmatched',
  undefined, undefined, undefined, // most likes carry no message, mirroring real usage
];

function generateProceduralProfiles(count: number): SeedProfile[] {
  const rand = mulberry32(42);
  const pick = <T,>(arr: T[]): T => arr[Math.floor(rand() * arr.length)];

  return Array.from({ length: count }, (_, i) => {
    const genderIdentity = pick(GENDERS);
    const prompt = pick(PROMPTS);
    const tags = [...TAGS_POOL].sort(() => rand() - 0.5).slice(0, 2 + Math.floor(rand() * 2));

    return {
      handle: `test${i + 1}`,
      name: pick(FIRST_NAMES),
      photoHandle: PHOTO_HANDLES[i % PHOTO_HANDLES.length],
      genderIdentity,
      genderIdentityOther: genderIdentity === 'other' ? 'Genderfluid' : undefined,
      pronouns: pick(PRONOUNS_BY_GENDER[genderIdentity]),
      bio: pick(BIOS),
      styleTags: tags,
      age: 21 + Math.floor(rand() * 14),
      isVerified: rand() < 0.25,
      heightInches: 60 + Math.floor(rand() * 13),
      jobTitle: pick(JOBS),
      school: pick(SCHOOLS),
      prompt1Question: prompt.question,
      prompt1Answer: pick(prompt.answers),
      latJitter: (rand() - 0.5) * 0.1,
      lonJitter: (rand() - 0.5) * 0.1,
      likeMessage: rand() < 0.6 ? pick(LIKE_MESSAGES) : undefined,
    };
  });
}

const ALL_PROFILES: SeedProfile[] = [...PROFILES, ...generateProceduralProfiles(PROCEDURAL_COUNT)];

async function main() {
  const passwordHash = await hashPassword(TEST_PASSWORD);
  const base = await resolveRealUser();

  console.log(`Seeding ${ALL_PROFILES.length} test profiles (password for all: ${TEST_PASSWORD})`);
  console.log(`Anchored near "${base.city}" (${base.lat.toFixed(3)}, ${base.lon.toFixed(3)})`);
  if (base.id) {
    console.log(`Each profile already likes your real account — swipe right on any of them to instantly match.\n`);
  } else {
    console.log(`No real account found yet — sign up and complete onboarding, then re-run this to get pre-likes.\n`);
  }

  for (const [i, p] of ALL_PROFILES.entries()) {
    const email = `${p.handle}${SEED_TAG}@lumen.test`;
    const phone = `555${String(i).padStart(4, '0')}0000`.slice(0, 10);

    await prisma.user.deleteMany({ where: { email } });

    const user = await prisma.user.create({
      data: {
        name: p.name,
        email,
        phone,
        passwordHash,
        dateOfBirth: dateOfBirthForAge(p.age),
        genderIdentity: p.genderIdentity,
        genderIdentityOther: p.genderIdentityOther,
        femAttestationAccepted: true,
        femAttestationAcceptedAt: new Date(),
        emailVerified: true,
        bio: p.bio,
        pronouns: p.pronouns,
        styleTags: p.styleTags,
        heightInches: p.heightInches,
        jobTitle: p.jobTitle,
        school: p.school,
        prompt1Question: p.prompt1Question,
        prompt1Answer: p.prompt1Answer,
        isVerified: p.isVerified,
        latitude: base.lat + p.latJitter,
        longitude: base.lon + p.lonJitter,
        cityDisplay: base.city,
        discoverable: true,
      },
    });

    for (const tagName of p.styleTags) {
      await prisma.tag.upsert({ where: { name: tagName }, create: { name: tagName }, update: {} });
    }

    const photoBase = p.photoHandle ?? p.handle;
    const photoFilenames = [
      `${photoBase}.jpg`,
      `${photoBase}_2.jpg`,
      `${photoBase}_3.jpg`,
    ].filter((name) => fs.existsSync(path.join(__dirname, 'seed-assets', name)));

    for (const [order, filename] of photoFilenames.entries()) {
      const buffer = fs.readFileSync(path.join(__dirname, 'seed-assets', filename));
      const { url, thumbnailUrl } = await uploadPhoto(buffer, user.id);
      await prisma.photo.create({
        data: { userId: user.id, url, thumbnailUrl, order, moderationStatus: 'approved' },
      });
    }

    if (base.id) {
      await prisma.swipe.create({
        data: {
          swiperId: user.id,
          swipedId: base.id,
          direction: 'like',
          message: p.likeMessage,
        },
      });
    }

    console.log(`  ✓ ${email}  (${p.genderIdentity}${p.isVerified ? ', verified' : ''})`);
  }

  console.log(`\nDone. Log in as any of the above with password "${TEST_PASSWORD}".`);
  console.log(`Run "npm run seed:clean" to remove just these test profiles.`);
}

main()
  .catch((e) => {
    console.error(e);
    process.exit(1);
  })
  .finally(async () => {
    await prisma.$disconnect();
  });
