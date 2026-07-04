import { FastifyInstance } from 'fastify';
import { prisma } from '../server';
import { authenticate } from '../middleware/auth';
import { sendMessageSchema, zodErrorMessage } from '../utils/validation';
import { getPresignedUrl } from '../utils/storage';

export default async function matchRoutes(fastify: FastifyInstance) {
  // Get all matches
  fastify.get('/', { preHandler: authenticate }, async (request, reply) => {
    try {
      const matches = await prisma.match.findMany({
        where: {
          OR: [
            { userAId: request.userId },
            { userBId: request.userId },
          ],
          unmatchedAt: null,
        },
        include: {
          userA: {
            select: {
              id: true,
              genderIdentity: true,
              genderIdentityOther: true,
              dateOfBirth: true,
              cityDisplay: true,
              isVerified: true,
              photos: {
                where: { moderationStatus: 'approved' },
                orderBy: { order: 'asc' },
                take: 1,
              },
            },
          },
          userB: {
            select: {
              id: true,
              genderIdentity: true,
              genderIdentityOther: true,
              dateOfBirth: true,
              cityDisplay: true,
              isVerified: true,
              photos: {
                where: { moderationStatus: 'approved' },
                orderBy: { order: 'asc' },
                take: 1,
              },
            },
          },
          messages: {
            orderBy: { createdAt: 'desc' },
            take: 1,
          },
        },
        orderBy: { createdAt: 'desc' },
      });

      const formattedMatches = await Promise.all(
        matches.map(async (match) => {
          const otherUser = match.userAId === request.userId ? match.userB : match.userA;
          const lastMessage = match.messages[0];

          const photoUrl = otherUser.photos[0]
            ? await getPresignedUrl(otherUser.photos[0].url)
            : null;

          return {
            matchId: match.id,
            userId: otherUser.id,
            age: calculateAge(otherUser.dateOfBirth),
            genderIdentity: otherUser.genderIdentity,
            cityDisplay: otherUser.cityDisplay,
            isVerified: otherUser.isVerified,
            photo: photoUrl,
            lastMessage: lastMessage
              ? {
                  content: lastMessage.content,
                  senderId: lastMessage.senderId,
                  createdAt: lastMessage.createdAt,
                }
              : null,
            matchedAt: match.createdAt,
          };
        })
      );

      return reply.send({ matches: formattedMatches });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to fetch matches' });
    }
  });

  // Get messages for a match
  fastify.get('/:matchId/messages', { preHandler: authenticate }, async (request, reply) => {
    try {
      const { matchId } = request.params as { matchId: string };

      // Verify user is part of the match
      const match = await prisma.match.findUnique({
        where: { id: matchId },
      });

      if (!match) {
        return reply.status(404).send({ error: 'Match not found' });
      }

      if (match.userAId !== request.userId && match.userBId !== request.userId) {
        return reply.status(403).send({ error: 'Unauthorized' });
      }

      if (match.unmatchedAt) {
        return reply.status(400).send({ error: 'Match has been unmatched' });
      }

      const messages = await prisma.message.findMany({
        where: { matchId },
        orderBy: { createdAt: 'asc' },
      });

      // Mark messages as read
      await prisma.message.updateMany({
        where: {
          matchId,
          senderId: { not: request.userId },
          readAt: null,
        },
        data: {
          readAt: new Date(),
        },
      });

      return reply.send({ messages });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to fetch messages' });
    }
  });

  // Send a message
  fastify.post('/:matchId/messages', { preHandler: authenticate }, async (request, reply) => {
    try {
      const { matchId } = request.params as { matchId: string };
      const data = sendMessageSchema.parse(request.body);

      // Verify match exists and user is part of it
      const match = await prisma.match.findUnique({
        where: { id: matchId },
      });

      if (!match) {
        return reply.status(404).send({ error: 'Match not found' });
      }

      if (match.userAId !== request.userId && match.userBId !== request.userId) {
        return reply.status(403).send({ error: 'Unauthorized' });
      }

      if (match.unmatchedAt) {
        return reply.status(400).send({ error: 'Match has been unmatched' });
      }

      // If sending an image, check if message threshold is met
      if (data.imageUrl) {
        const messageCount = await prisma.message.count({
          where: { matchId },
        });

        const threshold = parseInt(process.env.IMAGE_MESSAGE_UNLOCK_THRESHOLD || '3');
        if (messageCount < threshold) {
          return reply.status(403).send({
            error: `Exchange at least ${threshold} messages before sending images`,
          });
        }
      }

      // Create message
      const message = await prisma.message.create({
        data: {
          matchId,
          senderId: request.userId!,
          content: data.content,
          imageUrl: data.imageUrl,
        },
      });

      return reply.status(201).send({ message });
    } catch (error: any) {
      fastify.log.error(error);
      
      if (error.name === 'ZodError') {
        return reply.status(400).send({ error: zodErrorMessage(error) });
      }
      
      return reply.status(500).send({ error: 'Failed to send message' });
    }
  });

  // Unmatch
  fastify.delete('/:matchId', { preHandler: authenticate }, async (request, reply) => {
    try {
      const { matchId } = request.params as { matchId: string };

      const match = await prisma.match.findUnique({
        where: { id: matchId },
      });

      if (!match) {
        return reply.status(404).send({ error: 'Match not found' });
      }

      if (match.userAId !== request.userId && match.userBId !== request.userId) {
        return reply.status(403).send({ error: 'Unauthorized' });
      }

      // Mark as unmatched
      await prisma.match.update({
        where: { id: matchId },
        data: {
          unmatchedAt: new Date(),
          unmatchedBy: request.userId,
        },
      });

      return reply.send({ message: 'Unmatched successfully' });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to unmatch' });
    }
  });
}

function calculateAge(dateOfBirth: Date): number {
  const today = new Date();
  let age = today.getFullYear() - dateOfBirth.getFullYear();
  const monthDiff = today.getMonth() - dateOfBirth.getMonth();
  
  if (monthDiff < 0 || (monthDiff === 0 && today.getDate() < dateOfBirth.getDate())) {
    age--;
  }
  
  return age;
}
