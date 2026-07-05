import 'dotenv/config';
import { Sentry } from './sentry';
import Fastify from 'fastify';
import cors from '@fastify/cors';
import jwt from '@fastify/jwt';
import rateLimit from '@fastify/rate-limit';
import fastifyStatic from '@fastify/static';
import multipart from '@fastify/multipart';
import websocket from '@fastify/websocket';
import Redis from 'ioredis';
import { PrismaClient } from '@prisma/client';
import path from 'path';

// Import routes
import authRoutes from './routes/auth';
import profileRoutes from './routes/profile';
import discoveryRoutes from './routes/discovery';
import swipeRoutes from './routes/swipe';
import matchRoutes from './routes/match';
import reportRoutes from './routes/report';
import blockRoutes from './routes/block';
import accountRoutes from './routes/account';
import verificationRoutes from './routes/verification';
import adminToolsRoutes from './routes/admin-tools';
import moderationRoutes from './routes/moderation';
import diagnosticsRoutes from './routes/diagnostics';
import { requireBasicAuth } from './middleware/basicAuth';

// Import socket handler
import { setupSocketHandlers } from './socket/handlers';

// Initialize clients
export const prisma = new PrismaClient();
export const redis = new Redis(process.env.REDIS_URL || 'redis://localhost:6379');

const fastify = Fastify({
  logger: {
    level: process.env.NODE_ENV === 'production' ? 'info' : 'debug',
  },
});

// Reports every 500-level route error to Sentry (in addition to Fastify's existing pino
// logging) before falling through to Fastify's normal error response — sending, not
// replacing, the existing log-based error visibility.
Sentry.setupFastifyErrorHandler(fastify);

// Both of these previously had no handler at all, so a truly uncaught error (bug in code that
// isn't inside a route's try/catch) would either crash the process silently or leave it in an
// undefined state — neither gets reported anywhere. Report to Sentry, then exit; the process
// manager (pm2, see ecosystem.config.js) is responsible for restarting it.
process.on('uncaughtException', (err) => {
  fastify.log.error(err, 'uncaughtException');
  Sentry.captureException(err);
  process.exit(1);
});

process.on('unhandledRejection', (reason) => {
  fastify.log.error(reason, 'unhandledRejection');
  Sentry.captureException(reason);
  process.exit(1);
});

// Register plugins
async function registerPlugins() {
  // CORS
  await fastify.register(cors, {
    origin: process.env.NODE_ENV === 'production' ? process.env.FRONTEND_URL : true,
    credentials: true,
  });

  // JWT
  await fastify.register(jwt, {
    secret: process.env.JWT_ACCESS_SECRET!,
    sign: {
      expiresIn: process.env.JWT_ACCESS_EXPIRY || '15m',
    },
  });

  // Rate limiting
  await fastify.register(rateLimit, {
    max: parseInt(process.env.RATE_LIMIT_MAX || '100'),
    timeWindow: parseInt(process.env.RATE_LIMIT_TIMEWINDOW || '60000'),
    redis: redis,
  });

  // Multipart form uploads (used by POST /profile/photos)
  await fastify.register(multipart, {
    limits: {
      fileSize: parseInt(process.env.MAX_PHOTO_SIZE_MB || '10') * 1024 * 1024,
    },
  });

  // Static file serving for uploaded photos (local dev mode)
  await fastify.register(fastifyStatic, {
    root: path.join(__dirname, '../uploads'),
    prefix: '/uploads/',
  });

  // Public marketing site (landing page, Privacy Policy, Terms of Service, Community
  // Guidelines) — see public/site/. Hosted on the same domain/deploy as the admin panel and
  // the API, but entirely separate from both: no auth, no links to /admin/ anywhere in it.
  // `extensions: ['html']` lets /privacy resolve to privacy.html on disk, so the linked-to URLs
  // (and the ones SettingsView.swift points at) don't need a literal .html suffix.
  await fastify.register(fastifyStatic, {
    root: path.join(__dirname, '../public/site'),
    prefix: '/',
    extensions: ['html'],
    decorateReply: false,
  });

  // Static admin site (login + report moderation) — see public/admin/. Wrapped in its own
  // plugin encapsulation so `requireBasicAuth` (an outer gate on top of the existing per-account
  // isAdmin JWT check every real admin action already requires — see middleware/auth.ts's
  // requireAdmin) applies to every request for anything under /admin/, including the bare HTML
  // shell, before a member of the public can even see that an admin login page exists.
  await fastify.register(async (instance) => {
    instance.addHook('onRequest', requireBasicAuth);
    await instance.register(fastifyStatic, {
      root: path.join(__dirname, '../public/admin'),
      prefix: '/admin/',
      decorateReply: false,
    });
  });

  await fastify.register(websocket);
}

// Register routes
async function registerRoutes() {
  await fastify.register(authRoutes, { prefix: '/auth' });
  await fastify.register(profileRoutes, { prefix: '/profile' });
  await fastify.register(discoveryRoutes, { prefix: '/discovery' });
  await fastify.register(swipeRoutes, { prefix: '/swipe' });
  await fastify.register(matchRoutes, { prefix: '/matches' });
  await fastify.register(reportRoutes, { prefix: '/reports' });
  await fastify.register(blockRoutes, { prefix: '/blocks' });
  await fastify.register(accountRoutes);
  await fastify.register(verificationRoutes, { prefix: '/verification' });

  // Both of these route files are admin-only in their entirety (unlike report.ts/verification.ts,
  // which mix public user-facing routes with a couple of admin sub-paths — those get
  // `requireBasicAuth` added directly to just their admin routes' preHandler chain instead), so
  // the same outer Basic Auth gate used for the static /admin/ site can wrap the whole
  // registration here.
  await fastify.register(async (instance) => {
    instance.addHook('onRequest', requireBasicAuth);
    await instance.register(adminToolsRoutes, { prefix: '/admin-tools' });
    await instance.register(moderationRoutes, { prefix: '/moderation' });
  });

  await fastify.register(diagnosticsRoutes, { prefix: '/diagnostics' });

  // Registers GET /ws — must happen before fastify.listen(), same as any other route.
  setupSocketHandlers(fastify);
}

// Health check
fastify.get('/health', async (request, reply) => {
  return { status: 'ok', timestamp: new Date().toISOString() };
});

// Start server
async function start() {
  try {
    await registerPlugins();
    await registerRoutes();

    // Prisma and ioredis both connect lazily on first query — pay that cost once here at boot
    // instead of on whichever real request happens to be first. The NSFW model used to be
    // preloaded here too, but photo moderation moved to a separate worker process (see
    // src/worker.ts / ROADMAP.md 2.7) specifically so this process never has to load or run it —
    // loading the same heavy model in both processes was fighting over RAM/CPU for nothing.
    await Promise.all([prisma.user.count(), redis.ping()]);

    const PORT = parseInt(process.env.PORT || '3000');
    await fastify.listen({ port: PORT, host: '0.0.0.0' });

    console.log(`🚀 Server ready at http://localhost:${PORT}`);
    console.log(`🔌 WebSocket ready at ws://localhost:${PORT}/ws`);
    console.log(`🛡️  Admin site at http://localhost:${PORT}/admin/`);
  } catch (err) {
    fastify.log.error(err);
    process.exit(1);
  }
}

// Graceful shutdown
const gracefulShutdown = async () => {
  console.log('\n🛑 Shutting down gracefully...');
  await fastify.close();
  await prisma.$disconnect();
  await redis.quit();
  process.exit(0);
};

// Guarded so importing this module (route files all pull in its `prisma`/`redis` exports)
// doesn't also bind a real port, re-register every plugin/route a second time, or install
// shutdown handlers that `fastify.close()` a server that was never started — tests need the
// `prisma`/`redis` singletons without any of the side effects of actually running the server.
// Vitest tears down each test file's worker process by signal, and without this guard that
// process death was routed through `gracefulShutdown` and threw ("Connection is closed") on top
// of whatever cleanup the test file's own `afterAll` had already done.
if (require.main === module) {
  process.on('SIGTERM', gracefulShutdown);
  process.on('SIGINT', gracefulShutdown);
  start();
}
