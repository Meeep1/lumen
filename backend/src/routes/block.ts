import { FastifyInstance } from 'fastify';
import { prisma } from '../server';
import { authenticate } from '../middleware/auth';
import { blockSchema, zodErrorMessage } from '../utils/validation';

export default async function blockRoutes(fastify: FastifyInstance) {
  // Block a user
  fastify.post('/', { preHandler: authenticate }, async (request, reply) => {
    try {
      const data = blockSchema.parse(request.body);

      // Check if blocking self
      if (request.userId === data.blockedId) {
        return reply.status(400).send({ error: 'Cannot block yourself' });
      }

      // Check if already blocked
      const existingBlock = await prisma.block.findUnique({
        where: {
          blockerId_blockedId: {
            blockerId: request.userId!,
            blockedId: data.blockedId,
          },
        },
      });

      if (existingBlock) {
        return reply.status(400).send({ error: 'User already blocked' });
      }

      // Create block
      await prisma.block.create({
        data: {
          blockerId: request.userId!,
          blockedId: data.blockedId,
        },
      });

      // Unmatch if there's an active match
      const [userA, userB] = [request.userId!, data.blockedId].sort();
      
      await prisma.match.updateMany({
        where: {
          userAId: userA,
          userBId: userB,
          unmatchedAt: null,
        },
        data: {
          unmatchedAt: new Date(),
          unmatchedBy: request.userId,
        },
      });

      return reply.status(201).send({ message: 'User blocked' });
    } catch (error: any) {
      fastify.log.error(error);
      
      if (error.name === 'ZodError') {
        return reply.status(400).send({ error: zodErrorMessage(error) });
      }
      
      return reply.status(500).send({ error: 'Failed to block user' });
    }
  });

  // Get blocked users
  fastify.get('/', { preHandler: authenticate }, async (request, reply) => {
    try {
      const blocks = await prisma.block.findMany({
        where: { blockerId: request.userId },
        include: {
          blocked: {
            select: {
              id: true,
              genderIdentity: true,
              photos: {
                where: { moderationStatus: 'approved' },
                orderBy: { order: 'asc' },
                take: 1,
              },
            },
          },
        },
        orderBy: { createdAt: 'desc' },
      });

      return reply.send({
        blocks: blocks.map((b) => ({
          id: b.id,
          userId: b.blockedId,
          blockedAt: b.createdAt,
        })),
      });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to fetch blocked users' });
    }
  });

  // Unblock a user
  fastify.delete('/:blockedId', { preHandler: authenticate }, async (request, reply) => {
    try {
      const { blockedId } = request.params as { blockedId: string };

      const block = await prisma.block.findUnique({
        where: {
          blockerId_blockedId: {
            blockerId: request.userId!,
            blockedId,
          },
        },
      });

      if (!block) {
        return reply.status(404).send({ error: 'Block not found' });
      }

      await prisma.block.delete({
        where: { id: block.id },
      });

      return reply.send({ message: 'User unblocked' });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to unblock user' });
    }
  });
}
