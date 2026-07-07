import { FastifyInstance } from 'fastify';
import { prisma, redis } from '../server';
import { authenticate } from '../middleware/auth';
import { sendMessageSchema, zodErrorMessage } from '../utils/validation';
import { getPresignedUrl, uploadChatImage } from '../utils/storage';
import { broadcastNewMessage } from '../socket/handlers';

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
              lastActiveAt: true,
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
              lastActiveAt: true,
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

          // Same `user:{id}:online` TTL key the socket layer already sets/refreshes (see
          // socket/handlers.ts's connect/ping handling) — reused here rather than adding a
          // second presence mechanism. Falls back to `lastActiveAt` (already tracked on every
          // login) for "Active 2h ago"-style display when not currently online.
          const isOnline = Boolean(await redis.get(`user:${otherUser.id}:online`));

          return {
            matchId: match.id,
            userId: otherUser.id,
            age: calculateAge(otherUser.dateOfBirth),
            genderIdentity: otherUser.genderIdentity,
            cityDisplay: otherUser.cityDisplay,
            isVerified: otherUser.isVerified,
            photo: photoUrl,
            isOnline,
            lastActiveAt: otherUser.lastActiveAt,
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

      // Same delivery (real-time push to both participants + APNs if the recipient's offline)
      // as a message sent over the socket — see broadcastNewMessage's own comment for why this
      // is a shared function rather than each path creating and delivering its own copy.
      await broadcastNewMessage(match, message);

      return reply.status(201).send({ message });
    } catch (error: any) {
      fastify.log.error(error);
      
      if (error.name === 'ZodError') {
        return reply.status(400).send({ error: zodErrorMessage(error) });
      }
      
      return reply.status(500).send({ error: 'Failed to send message' });
    }
  });

  // Send a photo message — a separate multipart endpoint rather than reusing POST
  // /:matchId/messages (which expects a JSON body with an already-hosted imageUrl), since this
  // one owns both the upload and the message creation in a single request. Deliberately **not**
  // run through moderateImage() — see uploadChatImage's own comment in storage.ts for why.
  fastify.post('/:matchId/messages/photo', { preHandler: authenticate }, async (request, reply) => {
    try {
      const { matchId } = request.params as { matchId: string };

      const match = await prisma.match.findUnique({ where: { id: matchId } });
      if (!match) {
        return reply.status(404).send({ error: 'Match not found' });
      }
      if (match.userAId !== request.userId && match.userBId !== request.userId) {
        return reply.status(403).send({ error: 'Unauthorized' });
      }
      if (match.unmatchedAt) {
        return reply.status(400).send({ error: 'Match has been unmatched' });
      }

      // Checked before even reading the upload off the wire — no point accepting a file for a
      // conversation that isn't unlocked for images yet.
      const messageCount = await prisma.message.count({ where: { matchId } });
      const threshold = parseInt(process.env.IMAGE_MESSAGE_UNLOCK_THRESHOLD || '3');
      if (messageCount < threshold) {
        return reply.status(403).send({
          error: `Exchange at least ${threshold} messages before sending images`,
        });
      }

      const data = await request.file();
      if (!data) {
        return reply.status(400).send({ error: 'No file uploaded' });
      }

      // @fastify/multipart's own fileSize limit throws FST_REQ_FILE_TOO_LARGE inside toBuffer()
      // for anything over the cap (see profile.ts's POST /photos for the full explanation) —
      // catch it here too so an oversized image gets the specific message instead of falling
      // through to this route's generic 500.
      const maxSize = parseInt(process.env.MAX_PHOTO_SIZE_MB || '10') * 1024 * 1024;
      let buffer: Buffer;
      try {
        buffer = await data.toBuffer();
      } catch (error: any) {
        if (error.code === 'FST_REQ_FILE_TOO_LARGE') {
          return reply.status(400).send({ error: `Photo is too large (max ${process.env.MAX_PHOTO_SIZE_MB || '10'}MB). Try a smaller photo.` });
        }
        throw error;
      }
      if (buffer.length > maxSize) {
        return reply.status(400).send({ error: `Photo is too large (max ${process.env.MAX_PHOTO_SIZE_MB || '10'}MB). Try a smaller photo.` });
      }

      const key = await uploadChatImage(buffer, matchId);
      // Stored fully-resolved (unlike Photo.url, which stores a bare key resolved at read time)
      // — Message.imageUrl has always been "whatever string the client displays directly" (see
      // sendMessageSchema's own comment), so resolving it once here keeps every other message
      // read path (GET /:matchId/messages, the socket broadcast payload) correct with zero
      // changes, instead of teaching each of them to presign on the way out.
      const imageUrl = await getPresignedUrl(key);

      const message = await prisma.message.create({
        data: { matchId, senderId: request.userId!, content: null, imageUrl },
      });

      await broadcastNewMessage(match, message);

      return reply.status(201).send({ message });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to send photo message' });
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
