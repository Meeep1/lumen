import { FastifyInstance } from 'fastify';
import appleSignin from 'apple-signin-auth';
import { prisma } from '../server';
import { hashPassword, verifyPassword, generateOTP, generateRefreshToken } from '../utils/auth';
import { sendOTPEmail } from '../utils/email';
import { resetTestAccount } from '../utils/testAccount';
import {
  signupSchema,
  verifyOTPSchema,
  resendOTPSchema,
  loginSchema,
  refreshTokenSchema,
  appleAuthSchema,
  zodErrorMessage,
} from '../utils/validation';

export default async function authRoutes(fastify: FastifyInstance) {
  // Signup - Step 1: Create account and send OTP
  // Tighter than the global default (server.ts) — this sends a real email and creates a DB row,
  // so it's a cheap way to spam either without a much lower per-IP ceiling than general traffic.
  fastify.post('/signup', { config: { rateLimit: { max: 5, timeWindow: 60000 } } }, async (request, reply) => {
    try {
      const data = signupSchema.parse(request.body);

      // Check if email or phone already exists
      const existingUser = await prisma.user.findFirst({
        where: {
          OR: [{ email: data.email }, { phone: data.phone }],
        },
      });

      if (existingUser) {
        return reply.status(400).send({
          error: existingUser.email === data.email
            ? 'Email already registered'
            : 'Phone number already registered',
        });
      }

      // Re-verify the Apple identity token here rather than trusting a client-supplied Apple
      // user ID directly — anyone could otherwise claim an arbitrary ID with no proof they
      // actually own that Apple account. Deriving it fresh from a freshly-verified token is the
      // only trustworthy source.
      let appleUserId: string | undefined;
      if (data.appleIdentityToken) {
        try {
          const appleData = await appleSignin.verifyIdToken(data.appleIdentityToken, {
            audience: process.env.APPLE_BUNDLE_ID || 'com.lumenfem.dating',
          });
          appleUserId = appleData.sub;
        } catch (err) {
          fastify.log.error(err);
          return reply.status(401).send({ error: 'Invalid Apple identity token' });
        }

        const existingApple = await prisma.user.findUnique({ where: { appleUserId } });
        if (existingApple) {
          return reply.status(400).send({ error: 'This Apple ID is already linked to an account' });
        }
      }

      // Generate OTP
      const otpCode = generateOTP();
      const otpExpiresAt = new Date(Date.now() + 10 * 60 * 1000); // 10 minutes

      // Hash password — skipped entirely for an Apple sign-up, which has no password at all
      const passwordHash = data.password ? await hashPassword(data.password) : null;

      // Create user
      const user = await prisma.user.create({
        data: {
          email: data.email,
          phone: data.phone,
          passwordHash,
          appleUserId,
          dateOfBirth: new Date(data.dateOfBirth),
          genderIdentity: data.genderIdentity,
          genderIdentityOther: data.genderIdentityOther,
          femAttestationAccepted: data.femAttestationAccepted,
          femAttestationAcceptedAt: new Date(),
          otpCode,
          otpExpiresAt,
          emailVerified: false,
        },
      });

      // Send OTP
      await sendOTPEmail(data.email, otpCode);

      return reply.status(201).send({
        message: 'Account created. Please verify your email.',
        userId: user.id,
      });
    } catch (error: any) {
      fastify.log.error(error);
      
      if (error.name === 'ZodError') {
        return reply.status(400).send({ error: zodErrorMessage(error) });
      }
      
      return reply.status(500).send({ error: 'Failed to create account' });
    }
  });

  // Verify OTP - Step 2: Verify email
  // Loose enough to allow a few mistyped-code retries, tight enough to make brute-forcing a
  // 6-digit code (1M combinations) impractical within any single OTP's expiry window.
  fastify.post('/verify-otp', { config: { rateLimit: { max: 10, timeWindow: 60000 } } }, async (request, reply) => {
    try {
      const data = verifyOTPSchema.parse(request.body);

      const user = await prisma.user.findUnique({
        where: { email: data.email },
      });

      if (!user) {
        return reply.status(404).send({ error: 'User not found' });
      }

      if (user.emailVerified) {
        return reply.status(400).send({ error: 'Email already verified' });
      }

      if (!user.otpCode || !user.otpExpiresAt) {
        return reply.status(400).send({ error: 'No OTP found. Please request a new one.' });
      }

      if (new Date() > user.otpExpiresAt) {
        return reply.status(400).send({ error: 'OTP expired. Please request a new one.' });
      }

      if (user.otpCode !== data.code) {
        return reply.status(400).send({ error: 'Invalid OTP code' });
      }

      // Mark email as verified
      await prisma.user.update({
        where: { id: user.id },
        data: {
          emailVerified: true,
          otpCode: null,
          otpExpiresAt: null,
        },
      });

      // Generate tokens
      const accessToken = fastify.jwt.sign({ userId: user.id });
      const refreshToken = generateRefreshToken();
      const refreshExpiresAt = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000); // 7 days

      await prisma.refreshToken.create({
        data: {
          token: refreshToken,
          userId: user.id,
          expiresAt: refreshExpiresAt,
        },
      });

      return reply.send({
        accessToken,
        refreshToken,
        user: {
          id: user.id,
          email: user.email,
          phone: user.phone,
          genderIdentity: user.genderIdentity,
        },
      });
    } catch (error: any) {
      fastify.log.error(error);
      
      if (error.name === 'ZodError') {
        return reply.status(400).send({ error: zodErrorMessage(error) });
      }
      
      return reply.status(500).send({ error: 'Failed to verify OTP' });
    }
  });

  // Resend OTP
  // The tightest of the auth limits — this is the one that sends a real email on every call
  // with no other side effect gating it (unlike signup, which at least requires a fresh,
  // not-already-registered email/phone first).
  fastify.post('/resend-otp', { config: { rateLimit: { max: 3, timeWindow: 60000 } } }, async (request, reply) => {
    try {
      const { email } = resendOTPSchema.parse(request.body);

      const user = await prisma.user.findUnique({
        where: { email },
      });

      if (!user) {
        return reply.status(404).send({ error: 'User not found' });
      }

      if (user.emailVerified) {
        return reply.status(400).send({ error: 'Email already verified' });
      }

      // Generate new OTP
      const otpCode = generateOTP();
      const otpExpiresAt = new Date(Date.now() + 10 * 60 * 1000);

      await prisma.user.update({
        where: { id: user.id },
        data: { otpCode, otpExpiresAt },
      });

      await sendOTPEmail(email, otpCode);

      return reply.send({ message: 'New OTP sent' });
    } catch (error: any) {
      fastify.log.error(error);

      if (error.name === 'ZodError') {
        return reply.status(400).send({ error: zodErrorMessage(error) });
      }

      return reply.status(500).send({ error: 'Failed to resend OTP' });
    }
  });

  // Login
  // Tighter than the global default — brute-forcing a password is exactly the traffic shape
  // (many requests, same IP, same endpoint) this needs to stop that generic per-route traffic
  // limits don't specifically target. 10/min still comfortably covers a real user mistyping
  // their password a few times.
  fastify.post('/login', { config: { rateLimit: { max: 10, timeWindow: 60000 } } }, async (request, reply) => {
    try {
      const data = loginSchema.parse(request.body);

      const user = await prisma.user.findUnique({
        where: { email: data.email },
      });

      if (!user) {
        return reply.status(401).send({ error: 'Invalid credentials' });
      }

      if (!user.emailVerified) {
        return reply.status(403).send({ error: 'Email not verified' });
      }

      if (!user.passwordHash) {
        return reply.status(400).send({ error: 'This account uses Sign in with Apple. There is no password to check.' });
      }

      const validPassword = await verifyPassword(user.passwordHash, data.password);
      if (!validPassword) {
        return reply.status(401).send({ error: 'Invalid credentials' });
      }

      if (user.isSuspended) {
        const expired = user.suspendedUntil !== null && user.suspendedUntil <= new Date();

        if (expired) {
          // A temporary suspension that has already lapsed must not block login — this used to
          // be a permanent lockout for anyone who tried to log back in after their suspension
          // ended, since login was the only way to get a token, and nothing else ever cleared
          // isSuspended for them.
          await prisma.user.update({
            where: { id: user.id },
            data: { isSuspended: false, suspendedUntil: null, suspensionReason: null },
          });
        } else {
          const message = user.suspendedUntil
            ? `Account suspended until ${user.suspendedUntil.toISOString()}`
            : 'Account suspended';
          return reply.status(403).send({ error: message, code: 'ACCOUNT_SUSPENDED' });
        }
      }

      // Update last active
      await prisma.user.update({
        where: { id: user.id },
        data: { lastActiveAt: new Date() },
      });

      // The App Store review account resets to a blank, pre-onboarding state on every real
      // login (not on token refresh) — see resetTestAccount's own comment for why.
      if (user.isTestAccount) {
        await resetTestAccount(prisma, user.id);
      }

      // Generate tokens
      const accessToken = fastify.jwt.sign({ userId: user.id });
      const refreshToken = generateRefreshToken();
      const refreshExpiresAt = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000);

      await prisma.refreshToken.create({
        data: {
          token: refreshToken,
          userId: user.id,
          expiresAt: refreshExpiresAt,
        },
      });

      return reply.send({
        accessToken,
        refreshToken,
        user: {
          id: user.id,
          email: user.email,
          phone: user.phone,
          genderIdentity: user.genderIdentity,
        },
      });
    } catch (error: any) {
      fastify.log.error(error);
      
      if (error.name === 'ZodError') {
        return reply.status(400).send({ error: zodErrorMessage(error) });
      }
      
      return reply.status(500).send({ error: 'Login failed' });
    }
  });

  // Sign in with Apple — logs in an existing Apple-linked (or matching-email) account. A brand
  // new identity with no matching account gets a distinct response telling the client to run
  // through the normal signup form (still need phone/email OTP, age, gender, fem attestation —
  // Apple only ever replaces the password step, never the rest of this app's requirements).
  fastify.post('/apple', async (request, reply) => {
    try {
      const data = appleAuthSchema.parse(request.body);

      let appleData;
      try {
        appleData = await appleSignin.verifyIdToken(data.identityToken, {
          audience: process.env.APPLE_BUNDLE_ID || 'com.lumenfem.dating',
        });
      } catch (err) {
        fastify.log.error(err);
        return reply.status(401).send({ error: 'Invalid Apple identity token' });
      }

      const appleUserId = appleData.sub;
      const email = appleData.email;

      let user = await prisma.user.findUnique({ where: { appleUserId } });

      // First time this Apple ID has been seen — if it matches an existing email/password
      // account, link them instead of creating a duplicate.
      if (!user && email) {
        const existingByEmail = await prisma.user.findUnique({ where: { email } });
        if (existingByEmail) {
          user = await prisma.user.update({ where: { id: existingByEmail.id }, data: { appleUserId } });
        }
      }

      if (!user) {
        return reply.status(404).send({
          error: 'No account found for this Apple ID',
          code: 'APPLE_SIGNUP_REQUIRED',
          email: email ?? null,
        });
      }

      if (!user.emailVerified) {
        return reply.status(403).send({ error: 'Email not verified' });
      }

      if (user.isSuspended) {
        const expired = user.suspendedUntil !== null && user.suspendedUntil <= new Date();

        if (expired) {
          await prisma.user.update({
            where: { id: user.id },
            data: { isSuspended: false, suspendedUntil: null, suspensionReason: null },
          });
        } else {
          const message = user.suspendedUntil
            ? `Account suspended until ${user.suspendedUntil.toISOString()}`
            : 'Account suspended';
          return reply.status(403).send({ error: message, code: 'ACCOUNT_SUSPENDED' });
        }
      }

      await prisma.user.update({ where: { id: user.id }, data: { lastActiveAt: new Date() } });

      const accessToken = fastify.jwt.sign({ userId: user.id });
      const refreshToken = generateRefreshToken();
      const refreshExpiresAt = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000);

      await prisma.refreshToken.create({
        data: { token: refreshToken, userId: user.id, expiresAt: refreshExpiresAt },
      });

      return reply.send({
        accessToken,
        refreshToken,
        user: {
          id: user.id,
          email: user.email,
          phone: user.phone,
          genderIdentity: user.genderIdentity,
        },
      });
    } catch (error: any) {
      fastify.log.error(error);

      if (error.name === 'ZodError') {
        return reply.status(400).send({ error: zodErrorMessage(error) });
      }

      return reply.status(500).send({ error: 'Apple sign-in failed' });
    }
  });

  // Refresh token
  fastify.post('/refresh', async (request, reply) => {
    try {
      const data = refreshTokenSchema.parse(request.body);

      const storedToken = await prisma.refreshToken.findUnique({
        where: { token: data.refreshToken },
        include: { user: true },
      });

      if (!storedToken) {
        return reply.status(401).send({ error: 'Invalid refresh token' });
      }

      if (new Date() > storedToken.expiresAt) {
        await prisma.refreshToken.delete({ where: { id: storedToken.id } });
        return reply.status(401).send({ error: 'Refresh token expired' });
      }

      // Generate new access token
      const accessToken = fastify.jwt.sign({ userId: storedToken.userId });

      return reply.send({ accessToken });
    } catch (error: any) {
      fastify.log.error(error);
      
      if (error.name === 'ZodError') {
        return reply.status(400).send({ error: zodErrorMessage(error) });
      }
      
      return reply.status(500).send({ error: 'Token refresh failed' });
    }
  });

  // Logout
  fastify.post('/logout', async (request, reply) => {
    try {
      const { refreshToken } = request.body as { refreshToken: string };

      if (refreshToken) {
        await prisma.refreshToken.deleteMany({
          where: { token: refreshToken },
        });
      }

      return reply.send({ message: 'Logged out successfully' });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Logout failed' });
    }
  });
}
