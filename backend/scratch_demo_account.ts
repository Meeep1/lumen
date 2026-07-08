import 'dotenv/config';
import fs from 'fs';
import path from 'path';
import { prisma } from './src/server';
import { hashPassword } from './src/utils/auth';
import { uploadPhoto } from './src/utils/storage';

const DEMO_EMAIL = 'demo_screenshots@lumenfem.app';
const DEMO_PASSWORD = 'DemoScreens2026!';

async function main() {
  await prisma.user.deleteMany({ where: { email: DEMO_EMAIL } });

  const passwordHash = await hashPassword(DEMO_PASSWORD);

  const user = await prisma.user.create({
    data: {
      email: DEMO_EMAIL,
      phone: '+15555559999',
      passwordHash,
      emailVerified: true,
      dateOfBirth: new Date('1998-06-15'),
      genderIdentity: 'woman',
      femAttestationAccepted: true,
      femAttestationAcceptedAt: new Date(),
      bio: "Golden retriever energy, cottagecore soul. Always down for a coffee crawl or a spontaneous road trip. Looking for someone who laughs easily and loves as hard as they live.",
      pronouns: 'she/her',
      styleTags: ['cottagecore', 'coffee-lover', 'bookworm', 'hiking'],
      heightInches: 65,
      jobTitle: 'Graphic Designer',
      school: 'Ohio State',
      prompt1Question: 'My ideal Sunday...',
      prompt1Answer: 'Farmers market, a good book, and a nap in a sunbeam.',
      prompt2Question: 'The way to win me over is...',
      prompt2Answer: 'Send me a playlist that actually slaps.',
      prompt3Question: "I'm looking for...",
      prompt3Answer: 'Someone who texts back and means it.',
      latitude: 39.9612,
      longitude: -82.9988,
      cityDisplay: 'Columbus, OH',
      isVerified: true,
      isActive: true,
      discoverable: true,
      isSuspended: false,
      isTestAccount: false,
    },
  });

  const photoSet = ['iris.jpg', 'iris_2.jpg', 'iris_3.jpg'];
  for (const [order, filename] of photoSet.entries()) {
    const buffer = fs.readFileSync(path.join(__dirname, 'prisma/seed-assets', filename));
    const { url, thumbnailUrl } = await uploadPhoto(buffer, user.id);
    await prisma.photo.create({
      data: { userId: user.id, url, thumbnailUrl, order, moderationStatus: 'approved' },
    });
  }

  console.log('Demo account ready:', DEMO_EMAIL, '/', DEMO_PASSWORD);
  console.log('User id:', user.id);
}

main().then(() => process.exit(0)).catch((e) => { console.error(e); process.exit(1); });
