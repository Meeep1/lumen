import { Queue } from 'bullmq';

// A plain options object, not a `Redis` instance — BullMQ bundles its own (slightly different)
// version of ioredis internally, and passing an instance built from the top-level `ioredis`
// package (the one server.ts's `redis` export uses) trips a structural type mismatch between
// the two copies even though they're functionally identical at runtime. A plain object sidesteps
// that entirely: BullMQ constructs its own internal client from it. `maxRetriesPerRequest: null`
// is a hard BullMQ requirement for any connection it's given.
const redisUrl = new URL(process.env.REDIS_URL || 'redis://localhost:6379');
export const queueConnectionOptions = {
  host: redisUrl.hostname,
  port: redisUrl.port ? Number(redisUrl.port) : 6379,
  password: redisUrl.password || undefined,
  db: redisUrl.pathname && redisUrl.pathname.length > 1 ? Number(redisUrl.pathname.slice(1)) : 0,
  maxRetriesPerRequest: null as null,
};

export interface PhotoModerationJob {
  photoId: string;
}

/// Photo moderation (NSFWJS classification, see utils/storage.ts's moderateImage) is 5-12
/// seconds of blocking, synchronous CPU work — genuinely blocking, not just slow, since it runs
/// on Node's single thread with no native/GPU acceleration in this environment (see the
/// recalibration history in moderateImage's own comments). Running it inline on the upload
/// request meant every *other* user's swipes/messages/page loads stalled for that entire window
/// whenever anyone uploaded a photo. This queue moves the actual classification into a separate
/// OS process (`src/worker.ts`, run as its own pm2 process — see ecosystem.config.js) so the API
/// process's event loop is never blocked by it, regardless of how many uploads happen at once.
export const photoModerationQueue = new Queue('photo-moderation', {
  connection: queueConnectionOptions,
  defaultJobOptions: {
    attempts: 3,
    backoff: { type: 'exponential', delay: 5000 },
    removeOnComplete: { count: 500 },
    removeOnFail: { count: 500 },
  },
});
