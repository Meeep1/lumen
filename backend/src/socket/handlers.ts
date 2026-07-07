import { FastifyInstance } from 'fastify';
import type { WebSocket } from 'ws';
import type { Match, Message } from '@prisma/client';
import jwt from 'jsonwebtoken';
import IORedis from 'ioredis';
import { prisma, redis } from '../server';
import { sendPushNotification } from '../utils/apns';

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

/// Delivers an already-created message in real time and, if the recipient isn't currently
/// online, pushes it — the one place this happens, called from both a socket 'send_message' and
/// the REST POST /matches/:matchId/messages (see routes/match.ts), so a message only ever gets
/// created once regardless of which path the client used, instead of each path creating (and
/// broadcasting) its own separate row for the same logical send.
export async function broadcastNewMessage(match: Match, created: Message): Promise<void> {
  const payload = {
    messageId: created.id,
    matchId: created.matchId,
    senderId: created.senderId,
    content: created.content,
    imageUrl: created.imageUrl,
    createdAt: created.createdAt,
  };

  // Both participants get it (sender included) — mirrors the old Socket.IO room broadcast,
  // which included the sender's own socket too; the client dedupes by message id.
  sendToUser(match.userAId, 'new_message', payload);
  sendToUser(match.userBId, 'new_message', payload);

  const otherUserId = match.userAId === created.senderId ? match.userBId : match.userAId;
  const isOnline = await redis.get(`user:${otherUserId}:online`);
  if (!isOnline) {
    const recipient = await prisma.user.findUnique({
      where: { id: otherUserId },
      select: { notifyNewMessage: true, pushToken: true },
    });
    if (recipient?.notifyNewMessage && recipient.pushToken) {
      const result = await sendPushNotification(recipient.pushToken, {
        title: 'New Message',
        body: created.content ? created.content.slice(0, 100) : 'Sent you a photo',
        data: { matchId: created.matchId },
      });
      if (!result.ok && result.reason === 'invalid-token') {
        await prisma.user.update({
          where: { id: otherUserId },
          data: { pushToken: null, pushPlatform: null },
        });
      }
    }
  }
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

/// The photo-moderation worker (src/worker.ts) runs as its own OS process — deliberately, so
/// the 5-12s of blocking CPU work NSFWJS classification takes never stalls this process's event
/// loop (see queue.ts). That means it has no access to `userSockets` above, which only exists in
/// this process's memory; there's no way to call `sendToUser` directly from over there. Redis
/// pub/sub bridges the gap: the worker publishes here once a photo's status is decided, and
/// this process (which does hold the live socket) relays it via the exact same `sendToUser`
/// path the admin's manual approve/reject already uses, so the client sees identical behavior
/// regardless of which side made the decision.
function subscribeToPhotoModerationEvents() {
  const subscriber = new IORedis(process.env.REDIS_URL || 'redis://localhost:6379');
  subscriber.subscribe('photo-reviewed').catch((err) => {
    console.error('Failed to subscribe to photo-reviewed channel:', err);
  });
  subscriber.on('message', (channel, message) => {
    if (channel !== 'photo-reviewed') return;
    try {
      const { userId, photoId, status } = JSON.parse(message);
      void notifyPhotoReviewed(userId, photoId, status);
    } catch (err) {
      console.error('Failed to handle photo-reviewed message:', err);
    }
  });
}

/// `sendToUser` alone (this function's previous body) only ever reaches a client with an
/// actively-open socket — silently dropped otherwise, with no push fallback at all, unlike every
/// other notification kind in this app (new match, new like, new message, report reviewed). That
/// meant a photo being approved or rejected while someone's phone was locked/backgrounded (the
/// common case — moderation now finishes in ~1s, well before most people are still staring at
/// the upload screen) never actually reached them. Mirrors report.ts's report_reviewed handling:
/// live socket event if online, a real APNs push if not.
async function notifyPhotoReviewed(userId: string, photoId: string, status: string) {
  const isOnline = await redis.get(`user:${userId}:online`);
  if (isOnline) {
    sendToUser(userId, 'photo_reviewed', { photoId, status });
    return;
  }

  const user = await prisma.user.findUnique({ where: { id: userId }, select: { pushToken: true } });
  if (!user?.pushToken) return;

  const result = await sendPushNotification(user.pushToken, {
    title: status === 'approved' ? 'Photo Approved' : 'Photo Not Approved',
    body:
      status === 'approved'
        ? 'One of your photos is now live on your profile.'
        : "One of your photos wasn't approved. Check Manage Photos for details.",
    data: { photoId, status },
  });
  if (!result.ok && result.reason === 'invalid-token') {
    await prisma.user.update({ where: { id: userId }, data: { pushToken: null, pushPlatform: null } });
  }
}

export function setupSocketHandlers(fastify: FastifyInstance) {
  subscribeToPhotoModerationEvents();

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

            await broadcastNewMessage(match, created);
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
