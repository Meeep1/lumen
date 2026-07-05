import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    setupFiles: ['./tests/setup.ts'],
    // These integration tests hit a real (test) Postgres + Redis and share Prisma/ioredis
    // singletons across the whole run — parallel test files racing on the same connections and
    // rows is a bigger risk than a slower sequential run for a suite this size.
    fileParallelism: false,
    testTimeout: 15000,
    hookTimeout: 15000,
  },
});
