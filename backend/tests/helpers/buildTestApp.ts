import Fastify, { FastifyInstance } from 'fastify';
import jwt from '@fastify/jwt';
import multipart from '@fastify/multipart';

import authRoutes from '../../src/routes/auth';
import profileRoutes from '../../src/routes/profile';
import discoveryRoutes from '../../src/routes/discovery';
import swipeRoutes from '../../src/routes/swipe';
import matchRoutes from '../../src/routes/match';
import reportRoutes from '../../src/routes/report';
import blockRoutes from '../../src/routes/block';
import accountRoutes from '../../src/routes/account';

/// Builds a fresh Fastify instance wired the same way `server.ts` registers things for real
/// (same route prefixes, same jwt config), but skips rate-limiting, CORS, static file serving,
/// and Sentry — none of that is what these tests are checking, and per-route rate limits
/// (see routes/auth.ts et al.) would otherwise throttle a test file that legitimately calls
/// `/auth/login` more than a handful of times. `server.ts`'s own `start()` never runs during
/// tests (guarded by `require.main === module`), so this is the only thing that actually
/// registers routes onto a running instance for the suite.
export async function buildTestApp(): Promise<FastifyInstance> {
  const app = Fastify({ logger: false });

  await app.register(jwt, {
    secret: process.env.JWT_ACCESS_SECRET!,
    sign: { expiresIn: process.env.JWT_ACCESS_EXPIRY || '15m' },
  });

  await app.register(multipart, {
    limits: { fileSize: 10 * 1024 * 1024 },
  });

  await app.register(authRoutes, { prefix: '/auth' });
  await app.register(profileRoutes, { prefix: '/profile' });
  await app.register(discoveryRoutes, { prefix: '/discovery' });
  await app.register(swipeRoutes, { prefix: '/swipe' });
  await app.register(matchRoutes, { prefix: '/matches' });
  await app.register(reportRoutes, { prefix: '/reports' });
  await app.register(blockRoutes, { prefix: '/blocks' });
  await app.register(accountRoutes);

  await app.ready();
  return app;
}
