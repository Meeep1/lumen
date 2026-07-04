import { FastifyInstance } from 'fastify';
import { prisma } from '../server';
import { authenticate, requireAdmin } from '../middleware/auth';
import { getPresignedUrl, deletePhoto, readPhoto, moderateImage } from '../utils/storage';
import { sendToUser } from '../socket/handlers';

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

      if (action === 'reject') {
        // Remove the file too — a rejected photo has no legitimate reason to keep existing on
        // disk, unlike a rejected verification selfie which stays for the review record.
        await deletePhoto(photo.url);
        await prisma.photo.delete({ where: { id: photoId } });

        // Same reorder-the-gap-away step as the user-facing DELETE /profile/photos/:id route.
        await prisma.photo.updateMany({
          where: { userId: photo.userId, order: { gt: photo.order } },
          data: { order: { decrement: 1 } },
        });

        sendToUser(photo.userId, 'photo_reviewed', { photoId, status: 'rejected' });
        return reply.send({ message: 'Photo rejected and removed' });
      }

      await prisma.photo.update({ where: { id: photoId }, data: { moderationStatus: 'approved' } });
      sendToUser(photo.userId, 'photo_reviewed', { photoId, status: 'approved' });
      return reply.send({ message: 'Photo approved' });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to act on photo' });
    }
  });

  // Re-runs moderateImage() against every already-approved photo — for catching content that
  // slipped through before a moderation change (model swap, threshold retune), since those
  // fixes only apply to new uploads by default. Rejects get deleted immediately (same as the
  // manual reject action); anything landing on "pending" goes to the review queue instead of
  // being auto-removed, since a rescan is exactly the kind of lower-confidence situation that
  // tier exists for.
  fastify.post('/rescan', { preHandler: [authenticate, requireAdmin] }, async (request, reply) => {
    try {
      // Each classification is ~5-12s of synchronous CPU work that blocks Node's single event
      // loop — running this over everything (200+ photos, mostly seed test data) previously
      // froze the whole server for other users for the better part of a rescan. Seed accounts
      // are synthetic test images we control, not real user content, so they don't need
      // re-checking; skipping them cuts this from ~200 photos down to a handful in practice.
      const photos = await prisma.photo.findMany({
        where: {
          moderationStatus: 'approved',
          user: { email: { not: { endsWith: '+seed@lumen.test' } } },
        },
      });

      let stillApproved = 0;
      let nowPending = 0;
      let nowRejected = 0;
      const flagged: { photoId: string; userEmail: string; status: string; labels: string[] }[] = [];

      for (const photo of photos) {
        const buffer = readPhoto(photo.url);
        const result = await moderateImage(buffer);
        // Yield to the event loop between photos so a long rescan doesn't starve real
        // requests for its entire duration — only helps between iterations, not during the
        // classification itself, but that's still better than nothing.
        await new Promise((resolve) => setImmediate(resolve));

        if (result.status === 'approved') {
          stillApproved++;
          await prisma.photo.update({ where: { id: photo.id }, data: { moderationLabels: result.labels } });
          continue;
        }

        const user = await prisma.user.findUnique({ where: { id: photo.userId }, select: { email: true } });
        flagged.push({ photoId: photo.id, userEmail: user?.email ?? photo.userId, status: result.status, labels: result.labels });

        if (result.status === 'rejected') {
          nowRejected++;
          await deletePhoto(photo.url);
          await prisma.photo.delete({ where: { id: photo.id } });
          await prisma.photo.updateMany({
            where: { userId: photo.userId, order: { gt: photo.order } },
            data: { order: { decrement: 1 } },
          });
          sendToUser(photo.userId, 'photo_reviewed', { photoId: photo.id, status: 'rejected' });
        } else {
          nowPending++;
          await prisma.photo.update({
            where: { id: photo.id },
            data: { moderationStatus: 'pending', moderationLabels: result.labels },
          });
          // Not sending a photo_reviewed event here — landing on "pending" isn't a final
          // decision the user needs telling about yet, it's still awaiting one.
        }
      }

      return reply.send({
        totalScanned: photos.length,
        stillApproved,
        nowPending,
        nowRejected,
        flagged,
      });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to rescan photos' });
    }
  });
}
