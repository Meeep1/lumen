import { FastifyInstance } from 'fastify';
import { beforeAll, afterAll, beforeEach, describe, expect, it } from 'vitest';
import { buildTestApp } from './helpers/buildTestApp';
import { cleanDb } from './helpers/cleanDb';
import { createUser } from './helpers/createUser';
import { prisma, redis } from '../src/server';

describe('block & report', () => {
  let app: FastifyInstance;

  beforeAll(async () => {
    app = await buildTestApp();
  });

  afterAll(async () => {
    await app.close();
    await prisma.$disconnect();
    await redis.quit();
  });

  beforeEach(async () => {
    await cleanDb();
  });

  it('creates a report', async () => {
    const reporter = await createUser(app);
    const reported = await createUser(app);

    const res = await app.inject({
      method: 'POST',
      url: '/reports',
      headers: { authorization: `Bearer ${reporter.accessToken}` },
      payload: { reportedId: reported.userId, reason: 'harassment', details: 'test report' },
    });
    expect(res.statusCode).toBe(201);

    const report = await prisma.report.findFirst({
      where: { reporterId: reporter.userId, reportedId: reported.userId },
    });
    expect(report).not.toBeNull();
    expect(report?.status).toBe('pending');
  });

  it('rejects reporting yourself', async () => {
    const a = await createUser(app);

    const res = await app.inject({
      method: 'POST',
      url: '/reports',
      headers: { authorization: `Bearer ${a.accessToken}` },
      payload: { reportedId: a.userId, reason: 'other' },
    });
    expect(res.statusCode).toBe(400);
  });

  it('blocks a user, and a swipe between them is then rejected', async () => {
    const a = await createUser(app);
    const b = await createUser(app);

    const blockRes = await app.inject({
      method: 'POST',
      url: '/blocks',
      headers: { authorization: `Bearer ${a.accessToken}` },
      payload: { blockedId: b.userId },
    });
    expect(blockRes.statusCode).toBe(201);

    const swipeRes = await app.inject({
      method: 'POST',
      url: '/swipe',
      headers: { authorization: `Bearer ${b.accessToken}` },
      payload: { swipedId: a.userId, direction: 'like' },
    });
    expect(swipeRes.statusCode).toBe(400);
  });

  it('rejects an unauthenticated report', async () => {
    const reported = await createUser(app);

    const res = await app.inject({
      method: 'POST',
      url: '/reports',
      payload: { reportedId: reported.userId, reason: 'other' },
    });
    expect(res.statusCode).toBe(401);
  });
});
