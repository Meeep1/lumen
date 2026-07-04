import { FastifyInstance } from 'fastify';
import type { WebSocket } from 'ws';
import jwt from 'jsonwebtoken';
import { prisma, redis } from '../server';

// Plain WebSocket instead of Socket.IO — the socket.io-client-swift SPM package couldn't be
// resolved in this environment's Xcode toolchain (headless package resolution never completed),
// so the client side uses Foundation's native URLSessionWebSocketTask instead. That meant
// dropping Socket.IO's room/broadcast abstraction here too, replaced with a simple per-user
// socket registry below.
interface ClientMessage {
  type: 'send_message' | 'typing' | 'mark_read' | 'ping';
  payload?: Record<string, unknown>;
}

// Every currently-connected socket for a user — a Set (not a single socket) so multiple
// devices/tabs for the same account all stay in sync.
const userSockets = new Map<string, Set<WebSocket>>();

function send(socket: WebSocket, type: string, payload: unknown) {
  if (socket.readyState === socket.OPEN) {
    socket.send(JSON.stringify({ type, payload }));
  }
}

/// Exported so the admin test-message tool (admin-tools.ts) can push a message over an
/// existing connection the same way a real chat send does, instead of the client having to
/// poll or reconnect to see it.
export function sendToUser(userId: string, type: string, payload: unknown) {
  const sockets = userSockets.get(userId);
  if (!sockets) return;
  for (const socket of sockets) send(socket, type, payload);
}

async function authenticateSocket(authHeader: string | undefined): Promise<string | null> {
  const token = authHeader?.startsWith('Bearer ') ? authHeader.slice(7) : undefined;
  if (!token) return null;
  try {
    const decoded = jwt.verify(token, process.env.JWT_ACCESS_SECRET!) as { userId: string };
    return decoded.userId;
  } catch {
    return null;
  }
}

export function setupSocketHandlers(fastify: FastifyInstance) {
  fastify.get('/ws', { websocket: true }, (socket, request) => {
    let userId: string | null = null;

    void (async () => {
      userId = await authenticateSocket(request.headers.authorization);
      if (!userId) {
        send(socket, 'error', { message: 'Authentication token required' });
        socket.close();
        return;
      }

      console.log(`User connected: ${userId}`);

      if (!userSockets.has(userId)) userSockets.set(userId, new Set());
      userSockets.get(userId)!.add(socket);

      await redis.set(`user:${userId}:online`, '1', 'EX', 300);
      send(socket, 'connected', { userId });
    })();

    socket.on('message', async (raw: Buffer) => {
      if (!userId) return;

      let message: ClientMessage;
      try {
        message = JSON.parse(raw.toString());
      } catch {
        return;
      }

      const currentUserId = userId;

      try {
        switch (message.type) {
          case 'send_message': {
            const { matchId, content, imageUrl } = message.payload as {
              matchId: string;
              content?: string;
              imageUrl?: string;
            };

            const match = await prisma.match.findUnique({ where: { id: matchId } });

            if (!match) {
              send(socket, 'error', { message: 'Match not found' });
              return;
            }
            if (match.userAId !== currentUserId && match.userBId !== currentUserId) {
              send(socket, 'error', { message: 'Unauthorized' });
              return;
            }
            if (match.unmatchedAt) {
              send(socket, 'error', { message: 'Match has been unmatched' });
              return;
            }

            if (imageUrl) {
              const messageCount = await prisma.message.count({ where: { matchId } });
              const threshold = parseInt(process.env.IMAGE_MESSAGE_UNLOCK_THRESHOLD || '3');
              if (messageCount < threshold) {
                send(socket, 'error', {
                  message: `Exchange at least ${threshold} messages before sending images`,
                });
                return;
              }
            }

            const created = await prisma.message.create({
              data: { matchId, senderId: currentUserId, content, imageUrl },
            });

            const payload = {
              messageId: created.id,
              matchId: created.matchId,
              senderId: created.senderId,
              content: created.content,
              imageUrl: created.imageUrl,
              createdAt: created.createdAt,
            };

            // Both participants get it (sender included) — mirrors the old Socket.IO room
            // broadcast, which included the sender's own socket too; the client already
            // dedupes by message id against its own optimistic/REST-sent copy.
            sendToUser(match.userAId, 'new_message', payload);
            sendToUser(match.userBId, 'new_message', payload);

            const otherUserId = match.userAId === currentUserId ? match.userBId : match.userAId;
            const isOnline = await redis.get(`user:${otherUserId}:online`);
            if (!isOnline) {
              // TODO: Send push notification via APNs
              console.log(`Send push notification to user ${otherUserId}`);
            }
            break;
          }

          case 'typing': {
            const { matchId, isTyping } = message.payload as { matchId: string; isTyping: boolean };

            const match = await prisma.match.findUnique({ where: { id: matchId } });
            if (!match || match.unmatchedAt) return;
            if (match.userAId !== currentUserId && match.userBId !== currentUserId) return;

            const otherUserId = match.userAId === currentUserId ? match.userBId : match.userAId;
            sendToUser(otherUserId, 'user_typing', { matchId, userId: currentUserId, isTyping });
            break;
          }

          case 'mark_read': {
            const { matchId } = message.payload as { matchId: string };

            const match = await prisma.match.findUnique({ where: { id: matchId } });
            if (!match || match.unmatchedAt) return;
            if (match.userAId !== currentUserId && match.userBId !== currentUserId) return;

            await prisma.message.updateMany({
              where: { matchId, senderId: { not: currentUserId }, readAt: null },
              data: { readAt: new Date() },
            });

            const otherUserId = match.userAId === currentUserId ? match.userBId : match.userAId;
            sendToUser(otherUserId, 'messages_read', { matchId, readBy: currentUserId });
            break;
          }

          case 'ping': {
            await redis.set(`user:${currentUserId}:online`, '1', 'EX', 300);
            send(socket, 'pong', {});
            break;
          }
        }
      } catch (error) {
        console.error('Error handling socket message:', error);
        send(socket, 'error', { message: 'Failed to process message' });
      }
    });

    socket.on('close', async () => {
      if (!userId) return;
      console.log(`User disconnected: ${userId}`);

      userSockets.get(userId)?.delete(socket);
      if (userSockets.get(userId)?.size === 0) {
        userSockets.delete(userId);
        await redis.del(`user:${userId}:online`);
      }
    });
  });
}
