// Runs before any test file imports app code (see vitest.config.ts's `setupFiles`) — setting
// these here, before `src/server.ts` (and the `prisma`/`redis` singletons it exports) gets
// imported by any route file, points the whole suite at a dedicated test database and a
// separate Redis DB index instead of whatever real dev/review data `.env` normally points at.
// Without this, running tests would create/delete real rows in the same Postgres the app you're
// actively using points at, and rate-limit counters would collide with real traffic.
//
// Only sets a default when the variable isn't already present, so CI (backend-tests.yml sets
// its own DATABASE_URL/JWT secrets for its Postgres/Redis service containers) takes precedence
// over the local-dev fallback used when running `npm test` on a machine.
process.env.DATABASE_URL ??= 'postgresql://camdenheil@localhost:5432/lumen_test?schema=public';
process.env.REDIS_URL ??= 'redis://localhost:6379/2';
process.env.JWT_ACCESS_SECRET ??= 'test-access-secret';
process.env.JWT_REFRESH_SECRET ??= 'test-refresh-secret';
// requireBasicAuth (middleware/basicAuth.ts) fails closed without these — no test currently
// exercises an admin route, but set them anyway so a future one doesn't hit a confusing 500
// from an unrelated "admin panel isn't configured" check.
process.env.ADMIN_BASIC_AUTH_USER ??= 'test-admin';
process.env.ADMIN_BASIC_AUTH_PASSWORD ??= 'test-admin-password';
process.env.NODE_ENV = 'test';
// Test uploads should never touch the real moderation model (slow, and not what's under test
// here) — storage.ts's moderateImage still runs, but there's nothing that needs a fast path
// today since these tests don't upload real photos through the NSFW pipeline.
