import { FastifyInstance } from 'fastify';
import { beforeAll, afterAll, beforeEach, describe, expect, it } from 'vitest';
import { buildTestApp } from './helpers/buildTestApp';
import { cleanDb } from './helpers/cleanDb';
import { createUser } from './helpers/createUser';
import { prisma, redis } from '../src/server';

describe('auth', () => {
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

  it('signs up, verifies OTP, and logs in', async () => {
    const { userId, accessToken, email } = await createUser(app);
    expect(userId).toBeTruthy();
    expect(accessToken).toBeTruthy();

    const loginRes = await app.inject({
      method: 'POST',
      url: '/auth/login',
      payload: { email, password: 'TestPass123!' },
    });
    expect(loginRes.statusCode).toBe(200);
    expect(loginRes.json().user.id).toBe(userId);
  });

  it('rejects login with the wrong password', async () => {
    const { email } = await createUser(app);

    const res = await app.inject({
      method: 'POST',
      url: '/auth/login',
      payload: { email, password: 'WrongPassword!' },
    });
    expect(res.statusCode).toBe(401);
  });

  it('rejects login for an unverified email', async () => {
    const email = `unverified-${Date.now()}@example.com`;
    await app.inject({
      method: 'POST',
      url: '/auth/signup',
      payload: {
        email,
        phone: '+15559990000',
        password: 'TestPass123!',
        dateOfBirth: '2000-01-01T00:00:00Z',
        genderIdentity: 'woman',
        femAttestationAccepted: true,
      },
    });

    const res = await app.inject({
      method: 'POST',
      url: '/auth/login',
      payload: { email, password: 'TestPass123!' },
    });
    expect(res.statusCode).toBe(403);
  });

  it('rejects signup for someone under the minimum age', async () => {
    const res = await app.inject({
      method: 'POST',
      url: '/auth/signup',
      payload: {
        email: `minor-${Date.now()}@example.com`,
        phone: '+15559990001',
        password: 'TestPass123!',
        // 17 years old as of "today" relative to the test run.
        dateOfBirth: new Date(Date.now() - 17 * 365.25 * 24 * 60 * 60 * 1000).toISOString(),
        genderIdentity: 'woman',
        femAttestationAccepted: true,
      },
    });
    expect(res.statusCode).toBe(400);
  });

  it('rejects signup without accepting the fem attestation', async () => {
    const res = await app.inject({
      method: 'POST',
      url: '/auth/signup',
      payload: {
        email: `noattestation-${Date.now()}@example.com`,
        phone: '+15559990002',
        password: 'TestPass123!',
        dateOfBirth: '2000-01-01T00:00:00Z',
        genderIdentity: 'woman',
        femAttestationAccepted: false,
      },
    });
    expect(res.statusCode).toBe(400);
  });

  it('rejects an incorrect OTP code', async () => {
    const email = `badotp-${Date.now()}@example.com`;
    await app.inject({
      method: 'POST',
      url: '/auth/signup',
      payload: {
        email,
        phone: '+15559990003',
        password: 'TestPass123!',
        dateOfBirth: '2000-01-01T00:00:00Z',
        genderIdentity: 'woman',
        femAttestationAccepted: true,
      },
    });

    const res = await app.inject({
      method: 'POST',
      url: '/auth/verify-otp',
      payload: { email, code: '000000' },
    });
    expect(res.statusCode).toBe(400);
  });
});
