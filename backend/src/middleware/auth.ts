import { FastifyRequest, FastifyReply } from 'fastify';
import { prisma } from '../server';

/// Verifies the JWT, then rejects suspended accounts on every request (not just at login) — a
/// suspended user's existing access token used to keep working everywhere else until it
/// naturally expired. Also opportunistically clears an expired temporary suspension so the
/// account doesn't stay locked past `suspendedUntil`. The isAdmin flag is fetched here too and
/// stashed on the request so `requireAdmin` doesn't need a second DB round trip.
export async function authenticate(request: FastifyRequest, reply: FastifyReply) {
  try {
    await request.jwtVerify();
    const payload = request.user as { userId: string };

    const user = await prisma.user.findUnique({
      where: { id: payload.userId },
      select: { isSuspended: true, suspendedUntil: true, isAdmin: true },
    });

    if (!user) {
      return reply.status(401).send({ error: 'Unauthorized' });
    }

    if (user.isSuspended) {
      const expired = user.suspendedUntil !== null && user.suspendedUntil <= new Date();

      if (expired) {
        await prisma.user.update({
          where: { id: payload.userId },
          data: { isSuspended: false, suspendedUntil: null, suspensionReason: null },
        });
      } else {
        const message = user.suspendedUntil
          ? `Account suspended until ${user.suspendedUntil.toISOString()}`
          : 'Account suspended';
        return reply.status(403).send({ error: message, code: 'ACCOUNT_SUSPENDED' });
      }
    }

    request.userId = payload.userId;
    request.userIsAdmin = user.isAdmin;
  } catch (err) {
    reply.status(401).send({ error: 'Unauthorized' });
  }
}

/// Chain after `authenticate`, which already fetched isAdmin — no extra query needed here.
export async function requireAdmin(request: FastifyRequest, reply: FastifyReply) {
  if (!request.userIsAdmin) {
    reply.status(403).send({ error: 'Admin access required' });
  }
}
