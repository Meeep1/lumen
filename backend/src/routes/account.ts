import { FastifyInstance } from 'fastify';
import { prisma } from '../server';
import { authenticate } from '../middleware/auth';
import { deleteAllUserPhotos, deleteChatImagesForMatches } from '../utils/storage';

export default async function accountRoutes(fastify: FastifyInstance) {
  // Self-service account deletion (required by App Store — app_spec.md Section 3.9).
  // Cascades to photos/swipes/matches/messages/reports-made/reports-received/blocks/refresh
  // tokens via onDelete: Cascade in schema.prisma. The cascade only removes the DB rows though —
  // the actual uploaded files (profile photos + verification selfie, and any chat images from
  // matches this account was part of) live on disk independently of those rows, so they're
  // deleted here explicitly. Without this, a "deleted" account's photos stayed servable forever
  // at their old /uploads/ URL (no ownership check on that static route), which defeats the
  // point of a privacy-motivated deletion feature.
  // Feedback is the one deliberate exception — its userId gets nulled out (onDelete: SetNull),
  // not deleted, since it's meant to outlive the account that sent it.
  fastify.delete('/account', { preHandler: authenticate }, async (request, reply) => {
    try {
      // Match rows (and everything under them) cascade-delete along with the user below, so
      // there's nothing left to query once that happens — the match ids have to be collected
      // first, purely to know which chat/{matchId}/ directories to clean up on disk afterward.
      const matches = await prisma.match.findMany({
        where: { OR: [{ userAId: request.userId }, { userBId: request.userId }] },
        select: { id: true },
      });

      await prisma.user.delete({ where: { id: request.userId } });
      deleteAllUserPhotos(request.userId!);
      deleteChatImagesForMatches(matches.map((m) => m.id));
      return reply.send({ message: 'Account deleted' });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to delete account' });
    }
  });
}
