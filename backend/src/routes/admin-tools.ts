// Temporary local testing tools, admin-only — NOT for production. Lets you send a message
// "as" one of the seeded test accounts to any real account, so you can see live message
// delivery on your own device without hand-crafting a match first.

import { FastifyInstance } from 'fastify';
import { prisma } from '../server';
import { authenticate, requireAdmin } from '../middleware/auth';
import { sendToUser } from '../socket/handlers';

export default async function adminToolsRoutes(fastify: FastifyInstance) {
  // List seed/test accounts an admin can send a message "as".
  fastify.get('/test-accounts', { preHandler: [authenticate, requireAdmin] }, async (request, reply) => {
    try {
      const accounts = await prisma.user.findMany({
        where: { email: { endsWith: '+seed@lumen.test' } },
        orderBy: { email: 'asc' },
        select: { id: true, email: true },
      });

      return reply.send({ accounts });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to fetch test accounts' });
    }
  });

  // Send a message as a chosen test account to a real user (looked up by email). Auto-creates
  // the match (or un-unmatches it) if one doesn't already exist — this is a testing shortcut,
  // real matches always require mutual likes via the normal swipe flow.
  fastify.post('/send-message', { preHandler: [authenticate, requireAdmin] }, async (request, reply) => {
    try {
      const { fromUserId, toEmail, content } = request.body as {
        fromUserId?: string;
        toEmail?: string;
        content?: string;
      };

      if (!fromUserId || !toEmail?.trim() || !content?.trim()) {
        return reply.status(400).send({ error: 'fromUserId, toEmail, and content are required' });
      }

      const fromUser = await prisma.user.findUnique({ where: { id: fromUserId } });
      if (!fromUser) {
        return reply.status(404).send({ error: 'Sender account not found' });
      }

      const toUser = await prisma.user.findUnique({ where: { email: toEmail.trim() } });
      if (!toUser) {
        return reply.status(404).send({ error: 'No account with that email' });
      }

      if (fromUser.id === toUser.id) {
        return reply.status(400).send({ error: 'Sender and recipient must be different accounts' });
      }

      const [userAId, userBId] = [fromUser.id, toUser.id].sort();

      let match = await prisma.match.findUnique({
        where: { userAId_userBId: { userAId, userBId } },
      });

      if (!match) {
        match = await prisma.match.create({ data: { userAId, userBId } });
      } else if (match.unmatchedAt) {
        match = await prisma.match.update({
          where: { id: match.id },
          data: { unmatchedAt: null, unmatchedBy: null },
        });
      }

      const message = await prisma.message.create({
        data: { matchId: match.id, senderId: fromUser.id, content: content.trim() },
      });

      const payload = {
        messageId: message.id,
        matchId: message.matchId,
        senderId: message.senderId,
        content: message.content,
        imageUrl: message.imageUrl,
        createdAt: message.createdAt,
      };

      // Push it live if either side has an open socket — same event the real chat send path
      // emits, so the recipient's ChatView needs no special-casing to receive it.
      sendToUser(userAId, 'new_message', payload);
      sendToUser(userBId, 'new_message', payload);

      return reply.status(201).send({ message: 'Sent', matchId: match.id });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to send test message' });
    }
  });
}
