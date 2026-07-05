import { FastifyInstance } from 'fastify';
import { beforeAll, afterAll, beforeEach, describe, expect, it } from 'vitest';
import { buildTestApp } from './helpers/buildTestApp';
import { cleanDb } from './helpers/cleanDb';
import { createUser } from './helpers/createUser';
import { prisma, redis } from '../src/server';

describe('account deletion cascade', () => {
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

  it('removes swipes, matches, reports, and blocks involving the deleted account', async () => {
    const a = await createUser(app);
    const b = await createUser(app);

    // Mutual like -> match, plus a report and a block, so there's something in every related
    // table that should disappear once `a` is deleted.
    await app.inject({
      method: 'POST',
      url: '/swipe',
      headers: { authorization: `Bearer ${a.accessToken}` },
      payload: { swipedId: b.userId, direction: 'like' },
    });
    await app.inject({
      method: 'POST',
      url: '/swipe',
      headers: { authorization: `Bearer ${b.accessToken}` },
      payload: { swipedId: a.userId, direction: 'like' },
    });
    await app.inject({
      method: 'POST',
      url: '/reports',
      headers: { authorization: `Bearer ${b.accessToken}` },
      payload: { reportedId: a.userId, reason: 'other' },
    });

    const matchBefore = await prisma.match.findFirst({
      where: { OR: [{ userAId: a.userId }, { userBId: a.userId }] },
    });
    expect(matchBefore).not.toBeNull();

    const deleteRes = await app.inject({
      method: 'DELETE',
      url: '/account',
      headers: { authorization: `Bearer ${a.accessToken}` },
    });
    expect(deleteRes.statusCode).toBe(200);

    const [userAfter, swipesAfter, matchAfter, reportsAfter] = await Promise.all([
      prisma.user.findUnique({ where: { id: a.userId } }),
      prisma.swipe.findMany({ where: { OR: [{ swiperId: a.userId }, { swipedId: a.userId }] } }),
      prisma.match.findFirst({ where: { OR: [{ userAId: a.userId }, { userBId: a.userId }] } }),
      prisma.report.findMany({ where: { OR: [{ reporterId: a.userId }, { reportedId: a.userId }] } }),
    ]);

    expect(userAfter).toBeNull();
    expect(swipesAfter).toHaveLength(0);
    expect(matchAfter).toBeNull();
    expect(reportsAfter).toHaveLength(0);

    // The other participant's own account and data must survive untouched.
    const bAfter = await prisma.user.findUnique({ where: { id: b.userId } });
    expect(bAfter).not.toBeNull();
  });

  it('rejects an unauthenticated deletion request', async () => {
    const res = await app.inject({ method: 'DELETE', url: '/account' });
    expect(res.statusCode).toBe(401);
  });

  it('a deleted account can no longer log in', async () => {
    const a = await createUser(app);

    await app.inject({
      method: 'DELETE',
      url: '/account',
      headers: { authorization: `Bearer ${a.accessToken}` },
    });

    const loginRes = await app.inject({
      method: 'POST',
      url: '/auth/login',
      payload: { email: a.email, password: 'TestPass123!' },
    });
    expect(loginRes.statusCode).toBe(401);
  });
});
