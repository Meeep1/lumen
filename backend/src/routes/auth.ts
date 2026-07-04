import { FastifyInstance } from 'fastify';
import appleSignin from 'apple-signin-auth';
import { prisma } from '../server';
import { hashPassword, verifyPassword, generateOTP, generateRefreshToken } from '../utils/auth';
import { sendOTP } from '../utils/sms';
import {
  signupSchema,
  verifyOTPSchema,
  loginSchema,
  refreshTokenSchema,
  appleAuthSchema,
  zodErrorMessage,
} from '../utils/validation';

export default async function authRoutes(fastify: FastifyInstance) {
  // Signup - Step 1: Create account and send OTP
  fastify.post('/signup', async (request, reply) => {
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
            audience: process.env.APPLE_BUNDLE_ID || 'com.camdenheil.lumen',
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
          phoneVerified: false,
        },
      });

      // Send OTP
      await sendOTP(data.phone, otpCode);

      return reply.status(201).send({
        message: 'Account created. Please verify your phone number.',
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

  // Verify OTP - Step 2: Verify phone number
  fastify.post('/verify-otp', async (request, reply) => {
    try {
      const data = verifyOTPSchema.parse(request.body);

      const user = await prisma.user.findUnique({
        where: { phone: data.phone },
      });

      if (!user) {
        return reply.status(404).send({ error: 'User not found' });
      }

      if (user.phoneVerified) {
        return reply.status(400).send({ error: 'Phone already verified' });
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

      // Mark phone as verified
      await prisma.user.update({
        where: { id: user.id },
        data: {
          phoneVerified: true,
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
  fastify.post('/resend-otp', async (request, reply) => {
    try {
      const { phone } = request.body as { phone: string };

      const user = await prisma.user.findUnique({
        where: { phone },
      });

      if (!user) {
        return reply.status(404).send({ error: 'User not found' });
      }

      if (user.phoneVerified) {
        return reply.status(400).send({ error: 'Phone already verified' });
      }

      // Generate new OTP
      const otpCode = generateOTP();
      const otpExpiresAt = new Date(Date.now() + 10 * 60 * 1000);

      await prisma.user.update({
        where: { id: user.id },
        data: { otpCode, otpExpiresAt },
      });

      await sendOTP(phone, otpCode);

      return reply.send({ message: 'New OTP sent' });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to resend OTP' });
    }
  });

  // Login
  fastify.post('/login', async (request, reply) => {
    try {
      const data = loginSchema.parse(request.body);

      const user = await prisma.user.findUnique({
        where: { email: data.email },
      });

      if (!user) {
        return reply.status(401).send({ error: 'Invalid credentials' });
      }

      if (!user.phoneVerified) {
        return reply.status(403).send({ error: 'Phone number not verified' });
      }

      if (!user.passwordHash) {
        return reply.status(400).send({ error: 'This account uses Sign in with Apple — there is no password to check.' });
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
  // through the normal signup form (still need phone/OTP, age, gender, fem attestation — Apple
  // only ever replaces the password step, never the rest of this app's requirements).
  fastify.post('/apple', async (request, reply) => {
    try {
      const data = appleAuthSchema.parse(request.body);

      let appleData;
      try {
        appleData = await appleSignin.verifyIdToken(data.identityToken, {
          audience: process.env.APPLE_BUNDLE_ID || 'com.camdenheil.lumen',
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

      if (!user.phoneVerified) {
        return reply.status(403).send({ error: 'Phone number not verified' });
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
