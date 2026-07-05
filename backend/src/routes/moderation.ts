import { FastifyInstance } from 'fastify';
import { prisma } from '../server';
import { authenticate, requireAdmin } from '../middleware/auth';
import { getPresignedUrl } from '../utils/storage';
import { sendToUser } from '../socket/handlers';
import { photoModerationQueue } from '../queue';

/// Admin review queue for photos moderateImage() couldn't confidently auto-approve or
/// auto-reject (status "pending" — see storage.ts). Rejected photos are never returned by any
/// user-facing query (they all filter moderationStatus: 'approved'), so this is purely for
/// admins to clear the queue, not something end users interact with.
export default async function moderationRoutes(fastify: FastifyInstance) {
  fastify.get('/photos', { preHandler: [authenticate, requireAdmin] }, async (request, reply) => {
    try {
      const { status } = request.query as { status?: string };

      const photos = await prisma.photo.findMany({
        where: { moderationStatus: (status as any) || 'pending' },
        orderBy: { createdAt: 'asc' },
        include: {
          user: { select: { id: true, email: true } },
        },
      });

      const results = await Promise.all(
        photos.map(async (photo) => ({
          id: photo.id,
          userId: photo.user.id,
          userEmail: photo.user.email,
          url: await getPresignedUrl(photo.url),
          status: photo.moderationStatus,
          labels: photo.moderationLabels,
          createdAt: photo.createdAt,
        }))
      );

      return reply.send({ photos: results });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to fetch photo queue' });
    }
  });

  fastify.post('/photos/:photoId/action', { preHandler: [authenticate, requireAdmin] }, async (request, reply) => {
    try {
      const { photoId } = request.params as { photoId: string };
      const { action } = request.body as { action: 'approve' | 'reject' };

      if (action !== 'approve' && action !== 'reject') {
        return reply.status(400).send({ error: 'action must be "approve" or "reject"' });
      }

      const photo = await prisma.photo.findUnique({ where: { id: photoId } });
      if (!photo) {
        return reply.status(404).send({ error: 'Photo not found' });
      }

      // Rejected photos are no longer deleted outright (file or row) — kept around so the
      // owner has something to appeal (see POST /profile/photos/:photoId/appeal). They still
      // stay out of every user-facing query (all filter moderationStatus: 'approved'), so this
      // has no visible effect beyond making an appeal possible. A human explicitly rejecting it
      // here (as opposed to moderateImage's auto-reject) means it's not eligible for appeal —
      // this WAS the second look; rejectedByAdminId is what the appeal check gates on.
      await prisma.photo.update({
        where: { id: photoId },
        data: {
          moderationStatus: action === 'approve' ? 'approved' : 'rejected',
          rejectedByAdminId: action === 'reject' ? request.userId : null,
        },
      });
      sendToUser(photo.userId, 'photo_reviewed', { photoId, status: action === 'approve' ? 'approved' : 'rejected' });
      return reply.send({ message: action === 'approve' ? 'Photo approved' : 'Photo rejected' });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to act on photo' });
    }
  });

  // Appeals — a user can ask for a second look at a rejected photo (see POST
  // /profile/photos/:photoId/appeal). Separate queue from the main Photos tab since it's a
  // fundamentally different question ("was the human/model wrong?" vs. "does this need one").
  fastify.get('/appeals', { preHandler: [authenticate, requireAdmin] }, async (request, reply) => {
    try {
      const { status } = request.query as { status?: string };

      const photos = await prisma.photo.findMany({
        where: { appealStatus: (status as any) || 'pending' },
        orderBy: { appealCreatedAt: 'asc' },
        include: { user: { select: { id: true, email: true } } },
      });

      const results = await Promise.all(
        photos.map(async (photo) => ({
          id: photo.id,
          userId: photo.user.id,
          userEmail: photo.user.email,
          url: await getPresignedUrl(photo.url),
          labels: photo.moderationLabels,
          appealStatus: photo.appealStatus,
          appealMessage: photo.appealMessage,
          appealCreatedAt: photo.appealCreatedAt,
        }))
      );

      return reply.send({ photos: results });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to fetch appeals' });
    }
  });

  fastify.post('/appeals/:photoId/action', { preHandler: [authenticate, requireAdmin] }, async (request, reply) => {
    try {
      const { photoId } = request.params as { photoId: string };
      const { action } = request.body as { action: 'approve' | 'deny' };

      if (action !== 'approve' && action !== 'deny') {
        return reply.status(400).send({ error: 'action must be "approve" or "deny"' });
      }

      const photo = await prisma.photo.findUnique({ where: { id: photoId } });
      if (!photo) {
        return reply.status(404).send({ error: 'Photo not found' });
      }
      if (photo.appealStatus !== 'pending') {
        return reply.status(400).send({ error: 'This photo has no pending appeal' });
      }

      await prisma.photo.update({
        where: { id: photoId },
        data: {
          appealStatus: action === 'approve' ? 'approved' : 'denied',
          appealReviewedById: request.userId,
          appealReviewedAt: new Date(),
          // Approving the appeal is the whole point of it — the photo goes live. Denying
          // leaves moderationStatus exactly as it was (still rejected), but this review *is*
          // a human looking at it — same as a manual reject, that makes it no longer eligible
          // for a further appeal (see rejectedByAdminId's role in POST /profile/photos/:id/appeal).
          ...(action === 'approve'
            ? { moderationStatus: 'approved' as const }
            : { rejectedByAdminId: request.userId }),
        },
      });

      sendToUser(photo.userId, 'photo_appeal_reviewed', {
        photoId,
        outcome: action === 'approve' ? 'approved' : 'denied',
      });

      return reply.send({ message: action === 'approve' ? 'Appeal approved, photo restored' : 'Appeal denied' });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to act on appeal' });
    }
  });

  // Re-runs moderateImage() against every already-approved photo — for catching content that
  // slipped through before a moderation change (model swap, threshold retune), since those
  // fixes only apply to new uploads by default. Rejects are marked, not deleted (same as the
  // manual reject action, see /photos/:photoId/action) so an appeal has something to review;
  // anything landing on "pending" goes to the review queue instead.
  fastify.post('/rescan', { preHandler: [authenticate, requireAdmin] }, async (request, reply) => {
    try {
      // Used to run every classification inline in this request — each one is 5-12s of
      // blocking CPU work with no native/GPU acceleration here, and looping that over 200+
      // photos previously froze the whole server for other users for the entire rescan (an
      // event-loop yield between photos helped a little, but only between iterations, never
      // during the classification itself). Now just enqueues the same job type a real upload
      // uses (see queue.ts/worker.ts) and lets the dedicated worker process work through them
      // — the API process is never blocked by any of it, regardless of queue depth. Seed
      // accounts are synthetic test images we control, not real user content, so they're
      // excluded same as before.
      const photos = await prisma.photo.findMany({
        where: {
          moderationStatus: 'approved',
          user: { email: { not: { endsWith: '+seed@lumen.test' } } },
        },
        select: { id: true },
      });

      await photoModerationQueue.addBulk(
        photos.map((photo) => ({ name: 'moderate', data: { photoId: photo.id } }))
      );

      return reply.send({
        queued: photos.length,
        message: `Queued ${photos.length} photo${photos.length === 1 ? '' : 's'} for rescanning — check the Pending/Rejected tabs shortly as the worker processes them.`,
      });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to rescan photos' });
    }
  });
}
