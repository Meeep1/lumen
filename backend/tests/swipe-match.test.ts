import { FastifyInstance } from 'fastify';
import { beforeAll, afterAll, beforeEach, describe, expect, it } from 'vitest';
import { buildTestApp } from './helpers/buildTestApp';
import { cleanDb } from './helpers/cleanDb';
import { createUser } from './helpers/createUser';
import { prisma, redis } from '../src/server';

describe('swipe & match', () => {
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

  it('does not create a match on a one-directional like', async () => {
    const a = await createUser(app);
    const b = await createUser(app);

    const res = await app.inject({
      method: 'POST',
      url: '/swipe',
      headers: { authorization: `Bearer ${a.accessToken}` },
      payload: { swipedId: b.userId, direction: 'like' },
    });
    expect(res.statusCode).toBe(200);
    expect(res.json().matched).toBe(false);

    const match = await prisma.match.findFirst({
      where: {
        OR: [
          { userAId: a.userId, userBId: b.userId },
          { userAId: b.userId, userBId: a.userId },
        ],
      },
    });
    expect(match).toBeNull();
  });

  it('creates a match when both users like each other', async () => {
    const a = await createUser(app);
    const b = await createUser(app);

    await app.inject({
      method: 'POST',
      url: '/swipe',
      headers: { authorization: `Bearer ${a.accessToken}` },
      payload: { swipedId: b.userId, direction: 'like' },
    });

    const secondSwipe = await app.inject({
      method: 'POST',
      url: '/swipe',
      headers: { authorization: `Bearer ${b.accessToken}` },
      payload: { swipedId: a.userId, direction: 'like' },
    });
    expect(secondSwipe.statusCode).toBe(200);
    expect(secondSwipe.json().matched).toBe(true);

    const match = await prisma.match.findFirst({
      where: {
        OR: [
          { userAId: a.userId, userBId: b.userId },
          { userAId: b.userId, userBId: a.userId },
        ],
      },
    });
    expect(match).not.toBeNull();
  });

  it('does not match when the second swipe is a pass', async () => {
    const a = await createUser(app);
    const b = await createUser(app);

    await app.inject({
      method: 'POST',
      url: '/swipe',
      headers: { authorization: `Bearer ${a.accessToken}` },
      payload: { swipedId: b.userId, direction: 'like' },
    });

    const secondSwipe = await app.inject({
      method: 'POST',
      url: '/swipe',
      headers: { authorization: `Bearer ${b.accessToken}` },
      payload: { swipedId: a.userId, direction: 'pass' },
    });
    expect(secondSwipe.json().matched).toBe(false);
  });

  it('rejects swiping on yourself', async () => {
    const a = await createUser(app);

    const res = await app.inject({
      method: 'POST',
      url: '/swipe',
      headers: { authorization: `Bearer ${a.accessToken}` },
      payload: { swipedId: a.userId, direction: 'like' },
    });
    expect(res.statusCode).toBe(400);
  });

  it('rejects swiping the same person twice', async () => {
    const a = await createUser(app);
    const b = await createUser(app);

    await app.inject({
      method: 'POST',
      url: '/swipe',
      headers: { authorization: `Bearer ${a.accessToken}` },
      payload: { swipedId: b.userId, direction: 'like' },
    });

    const res = await app.inject({
      method: 'POST',
      url: '/swipe',
      headers: { authorization: `Bearer ${a.accessToken}` },
      payload: { swipedId: b.userId, direction: 'pass' },
    });
    expect(res.statusCode).toBe(400);
  });

  it('rejects an unauthenticated swipe', async () => {
    const b = await createUser(app);

    const res = await app.inject({
      method: 'POST',
      url: '/swipe',
      payload: { swipedId: b.userId, direction: 'like' },
    });
    expect(res.statusCode).toBe(401);
  });
});
