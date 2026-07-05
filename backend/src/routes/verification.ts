import { randomInt } from 'crypto';
import { FastifyInstance } from 'fastify';
import { prisma } from '../server';
import { authenticate } from '../middleware/auth';
import { authenticateAdmin, requirePermission } from '../middleware/adminAuth';
import { uploadPhoto, getPresignedUrl } from '../utils/storage';

// Excludes visually-ambiguous characters (0/O, 1/I/L) since a reviewer has to read this back off
// a photo of it held up to a camera, not copy-paste it.
const CODE_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
const CODE_LENGTH = 6;
const CODE_TTL_MS = 10 * 60 * 1000;

function generateVerificationCode(): string {
  let code = '';
  for (let i = 0; i < CODE_LENGTH; i++) {
    code += CODE_ALPHABET[randomInt(CODE_ALPHABET.length)];
  }
  return code;
}

export default async function verificationRoutes(fastify: FastifyInstance) {
  // Issue a fresh code the app displays right before opening the camera and requires the user
  // to hold up in-frame — see the schema comment on User.verificationCode for why this exists.
  // Called again (overwriting the old code) if the user backs out and restarts, so a stale code
  // from an abandoned attempt is never still valid.
  fastify.get('/code', { preHandler: authenticate }, async (request, reply) => {
    try {
      const code = generateVerificationCode();
      const expiresAt = new Date(Date.now() + CODE_TTL_MS);

      await prisma.user.update({
        where: { id: request.userId },
        data: { verificationCode: code, verificationCodeExpiresAt: expiresAt },
      });

      return reply.send({ code, expiresAt });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to generate verification code' });
    }
  });

  // Submit (or resubmit) a verification selfie
  fastify.post('/submit', { preHandler: authenticate }, async (request, reply) => {
    try {
      const data = await request.file();

      if (!data) {
        return reply.status(400).send({ error: 'No file uploaded' });
      }

      // Sent as a form field ahead of the file part in the multipart body (see APIService's
      // submitVerificationPhoto) — @fastify/multipart only exposes fields that arrived before
      // the file it's currently parsing, hence the field-ordering requirement on the client.
      const submittedCode = (data.fields.code as { value?: unknown } | undefined)?.value;

      const user = await prisma.user.findUnique({
        where: { id: request.userId },
        select: { verificationCode: true, verificationCodeExpiresAt: true },
      });

      if (
        typeof submittedCode !== 'string' ||
        !user?.verificationCode ||
        submittedCode !== user.verificationCode ||
        !user.verificationCodeExpiresAt ||
        user.verificationCodeExpiresAt < new Date()
      ) {
        return reply.status(400).send({
          error: 'Your verification code expired. Get a new code and retake the selfie.',
        });
      }

      const buffer = await data.toBuffer();

      const maxSize = parseInt(process.env.MAX_PHOTO_SIZE_MB || '10') * 1024 * 1024;
      if (buffer.length > maxSize) {
        return reply.status(400).send({ error: 'File too large' });
      }

      const photoKey = await uploadPhoto(buffer, request.userId!, true);

      await prisma.user.update({
        where: { id: request.userId },
        data: {
          verificationPhotoUrl: photoKey,
          verificationStatus: 'pending',
          verificationReviewedById: null,
          verificationReviewedAt: null,
        },
      });

      return reply.status(201).send({ message: 'Verification photo submitted for review' });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to submit verification photo' });
    }
  });

  // Own verification status
  fastify.get('/status', { preHandler: authenticate }, async (request, reply) => {
    try {
      const user = await prisma.user.findUnique({
        where: { id: request.userId },
        select: {
          isVerified: true,
          verificationStatus: true,
          verificationPhotoUrl: true,
          verificationReviewedAt: true,
        },
      });

      if (!user) {
        return reply.status(404).send({ error: 'User not found' });
      }

      return reply.send({
        isVerified: user.isVerified,
        status: user.verificationStatus,
        photoUrl: user.verificationPhotoUrl ? await getPresignedUrl(user.verificationPhotoUrl) : null,
        reviewedAt: user.verificationReviewedAt,
      });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to fetch verification status' });
    }
  });

  // Admin: queue of pending verification requests
  fastify.get('/admin', { preHandler: [authenticateAdmin, requirePermission('verification')] }, async (request, reply) => {
    try {
      const { status } = request.query as { status?: string };

      const users = await prisma.user.findMany({
        where: { verificationStatus: (status as any) || 'pending' },
        orderBy: { createdAt: 'asc' },
        select: {
          id: true,
          email: true,
          verificationStatus: true,
          verificationPhotoUrl: true,
          verificationCode: true,
          photos: {
            where: { moderationStatus: 'approved' },
            orderBy: { order: 'asc' },
            take: 3,
          },
        },
      });

      const requests = await Promise.all(
        users.map(async (u) => ({
          userId: u.id,
          email: u.email,
          status: u.verificationStatus,
          selfieUrl: u.verificationPhotoUrl ? await getPresignedUrl(u.verificationPhotoUrl) : null,
          // The code the user was required to hold up on-camera for this submission — reviewers
          // should reject anything where it isn't legibly visible in the selfie, since that's the
          // whole point (see schema.prisma's User.verificationCode comment).
          expectedCode: u.verificationCode,
          profilePhotoUrls: await Promise.all(u.photos.map((p) => getPresignedUrl(p.url))),
        }))
      );

      return reply.send({ requests });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to fetch verification queue' });
    }
  });

  // Admin: approve/reject a verification request
  fastify.post('/admin/:userId/action', { preHandler: [authenticateAdmin, requirePermission('verification')] }, async (request, reply) => {
    try {
      const { userId } = request.params as { userId: string };
      const { action } = request.body as { action: 'approve' | 'reject' };

      if (action !== 'approve' && action !== 'reject') {
        return reply.status(400).send({ error: 'action must be "approve" or "reject"' });
      }

      const user = await prisma.user.findUnique({ where: { id: userId } });
      if (!user) {
        return reply.status(404).send({ error: 'User not found' });
      }

      await prisma.user.update({
        where: { id: userId },
        data: {
          isVerified: action === 'approve',
          verificationStatus: action === 'approve' ? 'approved' : 'rejected',
          verificationReviewedById: request.adminId,
          verificationReviewedAt: new Date(),
        },
      });

      return reply.send({ message: `Verification ${action}d` });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to act on verification request' });
    }
  });
}
