import { FastifyInstance } from 'fastify';
import { prisma } from '../server';
import { authenticate } from '../middleware/auth';
import { deleteAllUserPhotos } from '../utils/storage';

export default async function accountRoutes(fastify: FastifyInstance) {
  // Self-service account deletion (required by App Store — app_spec.md Section 3.9).
  // Cascades to photos/swipes/matches/messages/reports-made/reports-received/blocks/refresh
  // tokens via onDelete: Cascade in schema.prisma. The cascade only removes the DB rows though —
  // the actual uploaded files (profile photos + verification selfie) live on disk independently
  // of those rows, so they're deleted here explicitly. Without this, a "deleted" account's photos
  // stayed servable forever at their old /uploads/ URL (no ownership check on that static route),
  // which defeats the point of a privacy-motivated deletion feature.
  // Feedback is the one deliberate exception — its userId gets nulled out (onDelete: SetNull),
  // not deleted, since it's meant to outlive the account that sent it.
  fastify.delete('/account', { preHandler: authenticate }, async (request, reply) => {
    try {
      await prisma.user.delete({ where: { id: request.userId } });
      deleteAllUserPhotos(request.userId!);
      return reply.send({ message: 'Account deleted' });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to delete account' });
    }
  });
}
