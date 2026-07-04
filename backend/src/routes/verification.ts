import { FastifyInstance } from 'fastify';
import { prisma } from '../server';
import { authenticate, requireAdmin } from '../middleware/auth';
import { uploadPhoto, getPresignedUrl } from '../utils/storage';

export default async function verificationRoutes(fastify: FastifyInstance) {
  // Submit (or resubmit) a verification selfie
  fastify.post('/submit', { preHandler: authenticate }, async (request, reply) => {
    try {
      const data = await request.file();

      if (!data) {
        return reply.status(400).send({ error: 'No file uploaded' });
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
  fastify.get('/admin', { preHandler: [authenticate, requireAdmin] }, async (request, reply) => {
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
  fastify.post('/admin/:userId/action', { preHandler: [authenticate, requireAdmin] }, async (request, reply) => {
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
          verificationReviewedById: request.userId,
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
