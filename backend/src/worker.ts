import 'dotenv/config';
import { Worker, Job } from 'bullmq';
import { prisma, redis } from './server';
import { readPhoto, moderateImage, preloadModerationModel } from './utils/storage';
import { queueConnectionOptions, PhotoModerationJob } from './queue';

/// Standalone entrypoint (run as its own pm2 process — see ecosystem.config.js) so the 5-12s of
/// blocking CPU work NSFWJS classification takes runs on a completely separate OS process from
/// the API. Importing `./server` here pulls in its `prisma`/`redis` exports the same way every
/// route file and the test suite already do — `server.ts`'s own `start()` (binding a real port)
/// is guarded behind `require.main === module`, which is this file when run directly, not
/// `server.ts`, so nothing there actually starts a second HTTP server.
async function processJob(job: Job) {
  const { photoId } = job.data as PhotoModerationJob;

  const photo = await prisma.photo.findUnique({ where: { id: photoId } });
  if (!photo) {
    console.warn(`photo-moderation: photo ${photoId} no longer exists, skipping`);
    return;
  }

  const buffer = readPhoto(photo.url);
  const result = await moderateImage(buffer);
  const previousStatus = photo.moderationStatus;

  await prisma.photo.update({
    where: { id: photoId },
    data: { moderationStatus: result.status, moderationLabels: result.labels },
  });

  // This same job type now backs both a brand-new upload (previousStatus is always 'pending',
  // the schema default) and an admin-triggered rescan of an already-approved photo (see
  // routes/moderation.ts's /rescan) — so "notify-worthy" has to mean an actual *transition*,
  // not just "landed on this status". Only a genuine change to a final approved/rejected verdict
  // gets a push: a rescan that confirms an already-approved photo stays approved is a no-op the
  // user doesn't need to hear about, and landing on "pending" (whether a new upload or a photo
  // just pulled from rescan) isn't a final decision yet — the client already reflects "pending"
  // via the photo's own status badge without needing a push for it.
  const isFinalVerdict = result.status === 'approved' || result.status === 'rejected';
  if (isFinalVerdict && result.status !== previousStatus) {
    await redis.publish(
      'photo-reviewed',
      JSON.stringify({ userId: photo.userId, photoId: photo.id, status: result.status })
    );
  }
}

async function main() {
  await preloadModerationModel();
  console.log('📸 Photo moderation worker ready');

  const worker = new Worker('photo-moderation', processJob, {
    connection: queueConnectionOptions,
    // NSFWJS classification is CPU-bound with no native/GPU acceleration in this environment
    // (see moderateImage's own comments) — concurrency above 1 wouldn't make classification
    // itself faster, just contend for the same CPU. Simplicity over a marginal, uncertain win.
    concurrency: 1,
    // BullMQ's default 30s job lock isn't long enough here: moderateImage()'s TensorFlow
    // classification is genuinely synchronous, CPU-blocking work for its whole 5-12+s run (worse
    // under load, since this process shares a single vCPU with the API, Postgres, and Redis) —
    // long enough to delay the lock's own renewal timer past the default lock duration. When that
    // happens the job is still actually running (and its DB update still lands) but BullMQ can no
    // longer prove it holds the lock, so it fails the job as "Missing lock for job N" and retries
    // a photo that had already finished. Set well above the worst observed classification time.
    lockDuration: 120000,
  });

  worker.on('failed', (job, err) => {
    console.error(`photo-moderation job ${job?.id} failed:`, err);
  });

  const shutdown = async () => {
    console.log('\n🛑 Worker shutting down gracefully...');
    await worker.close();
    await prisma.$disconnect();
    await redis.quit();
    process.exit(0);
  };
  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);
}

main().catch((err) => {
  console.error('Worker failed to start:', err);
  process.exit(1);
});
