import { FastifyInstance } from 'fastify';
import { prisma } from '../server';
import { authenticate } from '../middleware/auth';

export default async function accountRoutes(fastify: FastifyInstance) {
  // Self-service account deletion (required by App Store — app_spec.md Section 3.9).
  // Cascades to photos/swipes/matches/messages/reports-made/reports-received/blocks/refresh
  // tokens via onDelete: Cascade in schema.prisma.
  fastify.delete('/account', { preHandler: authenticate }, async (request, reply) => {
    try {
      await prisma.user.delete({ where: { id: request.userId } });
      return reply.send({ message: 'Account deleted' });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to delete account' });
    }
  });
}
