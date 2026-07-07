// Temporary local testing tools, admin-only — NOT for production. Lets you send a message
// "as" one of the seeded test accounts to any real account, so you can see live message
// delivery on your own device without hand-crafting a match first.

import { FastifyInstance } from 'fastify';
import { prisma } from '../server';
import { authenticateAdmin, requirePermission, requireSuperAdmin } from '../middleware/adminAuth';
import { sendToUser } from '../socket/handlers';
import { getPresignedUrl } from '../utils/storage';
import { sendPushNotification } from '../utils/apns';
import { logAdminView } from '../utils/adminAudit';

export default async function adminToolsRoutes(fastify: FastifyInstance) {
  // Full profile for the admin site's "View Profile" modal — used both from the Reports tab
  // (reviewing a reported user) and the Photos tab (context before approving/rejecting), so it
  // returns everything a moderator might need in one call: every photo regardless of moderation
  // status (unlike any user-facing profile query, which filters to approved-only), suspension
  // state, and account metadata.
  fastify.get('/users/:userId', { preHandler: [authenticateAdmin, requirePermission('reports', 'moderation')] }, async (request, reply) => {
    try {
      const { userId } = request.params as { userId: string };

      const user = await prisma.user.findUnique({
        where: { id: userId },
        include: { photos: { orderBy: { order: 'asc' } } },
      });

      if (!user) {
        return reply.status(404).send({ error: 'User not found' });
      }

      await logAdminView(request.adminId!, request.adminEmail!, 'view_profile', userId);

      const photos = await Promise.all(
        user.photos.map(async (photo) => ({
          id: photo.id,
          url: await getPresignedUrl(photo.url),
          order: photo.order,
          moderationStatus: photo.moderationStatus,
          moderationLabels: photo.moderationLabels,
        }))
      );

      return reply.send({
        id: user.id,
        email: user.email,
        phone: user.phone,
        dateOfBirth: user.dateOfBirth,
        genderIdentity: user.genderIdentity,
        genderIdentityOther: user.genderIdentityOther,
        bio: user.bio,
        pronouns: user.pronouns,
        styleTags: user.styleTags,
        heightInches: user.heightInches,
        jobTitle: user.jobTitle,
        school: user.school,
        prompt1Question: user.prompt1Question,
        prompt1Answer: user.prompt1Answer,
        prompt2Question: user.prompt2Question,
        prompt2Answer: user.prompt2Answer,
        prompt3Question: user.prompt3Question,
        prompt3Answer: user.prompt3Answer,
        cityDisplay: user.cityDisplay,
        isVerified: user.isVerified,
        isSuspended: user.isSuspended,
        suspendedUntil: user.suspendedUntil,
        suspensionReason: user.suspensionReason,
        isActive: user.isActive,
        discoverable: user.discoverable,
        createdAt: user.createdAt,
        lastActiveAt: user.lastActiveAt,
        photos,
      });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to fetch user profile' });
    }
  });

  // Chat transcript between two users, for the Reports tab's "View chat" — only meaningful if
  // they actually have a match; a report doesn't require one (you can report from a profile
  // view without ever matching), so `hasMatch: false` is a normal, expected response, not an
  // error.
  fastify.get('/messages', { preHandler: [authenticateAdmin, requirePermission('reports')] }, async (request, reply) => {
    try {
      const { userA, userB } = request.query as { userA?: string; userB?: string };
      if (!userA || !userB) {
        return reply.status(400).send({ error: 'userA and userB are required' });
      }

      const [userAId, userBId] = [userA, userB].sort();
      const match = await prisma.match.findUnique({
        where: { userAId_userBId: { userAId, userBId } },
      });

      if (!match) {
        return reply.send({ hasMatch: false, messages: [] });
      }

      await logAdminView(request.adminId!, request.adminEmail!, 'view_messages', userA, `with ${userB}`);

      const messages = await prisma.message.findMany({
        where: { matchId: match.id },
        orderBy: { createdAt: 'asc' },
      });

      return reply.send({
        hasMatch: true,
        unmatchedAt: match.unmatchedAt,
        messages: messages.map((m) => ({
          id: m.id,
          senderId: m.senderId,
          content: m.content,
          imageUrl: m.imageUrl,
          createdAt: m.createdAt,
        })),
      });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to fetch messages' });
    }
  });

  // Directory + search across every user — the admin panel's Users tab. Deliberately its own
  // permission ('users'), not reused from 'reports'/'moderation' — those only ever surface a
  // user someone already reported or a photo someone already flagged, while this exposes every
  // account regardless of any of that, so it gets its own opt-in grant rather than riding along
  // with a narrower one that was never meant to cover unrestricted browsing.
  fastify.get('/users', { preHandler: [authenticateAdmin, requirePermission('users')] }, async (request, reply) => {
    try {
      const { search, page: pageRaw } = request.query as { search?: string; page?: string };
      const page = Math.max(1, parseInt(pageRaw || '1', 10) || 1);
      const pageSize = 50;

      const where = search
        ? {
            OR: [
              { email: { contains: search, mode: 'insensitive' as const } },
              { phone: { contains: search } },
              { cityDisplay: { contains: search, mode: 'insensitive' as const } },
              { id: search },
            ],
          }
        : {};

      const [total, users] = await Promise.all([
        prisma.user.count({ where }),
        prisma.user.findMany({
          where,
          orderBy: { createdAt: 'desc' },
          skip: (page - 1) * pageSize,
          take: pageSize,
          select: {
            id: true,
            email: true,
            phone: true,
            cityDisplay: true,
            isVerified: true,
            isSuspended: true,
            isActive: true,
            createdAt: true,
            lastActiveAt: true,
          },
        }),
      ]);

      await logAdminView(request.adminId!, request.adminEmail!, 'view_user_list', undefined, search || undefined);

      return reply.send({ users, total, page, pageSize });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to fetch users' });
    }
  });

  // The audit trail itself — who's been looking at what, and when (see AdminAuditLog's own
  // schema.prisma comment). Super-admin only: letting a regular moderator read this would let
  // them check whether their own activity is being watched, which defeats the point.
  fastify.get('/audit-log', { preHandler: [authenticateAdmin, requireSuperAdmin] }, async (request, reply) => {
    try {
      const logs = await prisma.adminAuditLog.findMany({
        orderBy: { createdAt: 'desc' },
        take: 200,
      });
      return reply.send({ logs });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to fetch audit log' });
    }
  });

  // List seed/test accounts an admin can send a message "as".
  fastify.get('/test-accounts', { preHandler: [authenticateAdmin, requirePermission('testTools')] }, async (request, reply) => {
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
  fastify.post('/send-message', { preHandler: [authenticateAdmin, requirePermission('testTools')] }, async (request, reply) => {
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

  // Fixed order matching OnboardingView.swift's `Step` enum (plus the synthetic "completed"
  // event `finish()` logs) — not just whatever order happens to show up in the DB, so the
  // funnel always reads top-to-bottom the same way a real user actually walks through it.
  const ONBOARDING_STEP_ORDER = ['location', 'photo', 'about', 'height', 'details', 'prompts', 'tags', 'completed'];

  // Self-hosted onboarding funnel — see OnboardingEvent's own comment in schema.prisma for why
  // this exists instead of a third-party analytics SDK. Counts distinct *users* who reached each
  // step, not raw event rows (someone navigating back and forward through a step shouldn't
  // inflate its count) — done in application code rather than a SQL COUNT(DISTINCT ...) since
  // Prisma's groupBy doesn't expose that directly, and this table is small enough (a handful of
  // rows per user) that it's a non-issue.
  fastify.get('/onboarding-funnel', { preHandler: [authenticateAdmin, requirePermission('analytics')] }, async (request, reply) => {
    try {
      const events = await prisma.onboardingEvent.findMany({ select: { userId: true, step: true } });

      const usersByStep = new Map<string, Set<string>>();
      for (const event of events) {
        if (!usersByStep.has(event.step)) usersByStep.set(event.step, new Set());
        usersByStep.get(event.step)!.add(event.userId);
      }

      const funnel = ONBOARDING_STEP_ORDER.map((step) => ({
        step,
        userCount: usersByStep.get(step)?.size ?? 0,
      }));

      return reply.send({ funnel });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to compute onboarding funnel' });
    }
  });

  // Broadcast a custom push to every device with a registered token — announcing something to
  // the whole userbase (a new feature, planned downtime) without needing direct database
  // access. Deliberately no notifyXxx preference check, unlike per-event notifications: this is
  // a rare, admin-initiated announcement a person explicitly chose to send, not an automated
  // per-event notification someone should be able to individually opt out of. Runs synchronously
  // in the request — fine at this app's current user count; would need a background job if the
  // userbase ever grows into the thousands.
  fastify.post('/broadcast-push', { preHandler: [authenticateAdmin, requirePermission('testTools')] }, async (request, reply) => {
    try {
      const { title, body } = request.body as { title?: string; body?: string };
      if (!title?.trim() || !body?.trim()) {
        return reply.status(400).send({ error: 'title and body are required' });
      }

      const recipients = await prisma.user.findMany({
        where: { pushToken: { not: null } },
        select: { id: true, pushToken: true },
      });

      let sent = 0;
      let failed = 0;
      for (const recipient of recipients) {
        const result = await sendPushNotification(recipient.pushToken!, {
          title: title.trim(),
          body: body.trim(),
        });
        if (result.ok) {
          sent += 1;
        } else {
          failed += 1;
          if (result.reason === 'invalid-token') {
            await prisma.user.update({
              where: { id: recipient.id },
              data: { pushToken: null, pushPlatform: null },
            });
          }
        }
      }

      return reply.send({
        message: `Sent to ${sent} device${sent === 1 ? '' : 's'}${failed ? `, ${failed} failed` : ''}.`,
        sent,
        failed,
      });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to send broadcast' });
    }
  });
}
