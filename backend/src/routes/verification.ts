import { randomInt } from 'crypto';
import { FastifyInstance } from 'fastify';
import { prisma } from '../server';
import { authenticate } from '../middleware/auth';
import { authenticateAdmin, requirePermission } from '../middleware/adminAuth';
import { uploadPhoto, getPresignedUrl } from '../utils/storage';

// A "hold up this code" requirement (this file's previous version) tested badly — it doesn't
// match what any other dating app's verification flow looks like, so it read as an odd,
// unexplained hoop rather than a normal selfie check. A pose prompt gets the same anti-replay
// property (the app fetches a random one moments before the camera opens, so a photo prepared or
// downloaded in advance can't have anticipated it) via an ordinary gesture instead of an
// alphanumeric string — closer to the liveness prompts (blink, turn your head, smile) that
// Tinder/Bumble-style verification actually uses.
const POSES = [
  { id: 'peace-sign', label: 'Peace sign ✌️ next to your face' },
  { id: 'thumbs-up', label: 'Thumbs up 👍 next to your face' },
  { id: 'hand-on-chin', label: 'One hand resting on your chin 🤔' },
  { id: 'frame-face', label: 'Both hands framing your face 🙌' },
  { id: 'cover-one-eye', label: 'One hand covering one eye 🙈' },
  { id: 'wave', label: 'A wave 👋 at the camera' },
  { id: 'point-up', label: 'Pointing up next to your face ☝️' },
] as const;

const POSE_TTL_MS = 10 * 60 * 1000;

function pickRandomPose(): (typeof POSES)[number] {
  return POSES[randomInt(POSES.length)];
}

function findPoseLabel(poseId: string | null): string | null {
  return POSES.find((p) => p.id === poseId)?.label ?? null;
}

export default async function verificationRoutes(fastify: FastifyInstance) {
  // Issue a fresh pose prompt the app displays right before opening the camera and requires the
  // user to actually do in-frame — see this file's top comment for why a pose replaced a code,
  // and the schema comment on User.verificationPose for why the anti-replay mechanics stayed the
  // same underneath. Called again (overwriting the old one) if the user backs out and restarts,
  // so a stale prompt from an abandoned attempt is never still valid.
  fastify.get('/pose', { preHandler: authenticate }, async (request, reply) => {
    try {
      const pose = pickRandomPose();
      const expiresAt = new Date(Date.now() + POSE_TTL_MS);

      await prisma.user.update({
        where: { id: request.userId },
        data: { verificationPose: pose.id, verificationPoseExpiresAt: expiresAt },
      });

      return reply.send({ poseId: pose.id, poseLabel: pose.label, expiresAt });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to generate verification pose' });
    }
  });

  // Submit (or resubmit) a verification selfie
  fastify.post('/submit', { preHandler: authenticate }, async (request, reply) => {
    try {
      const data = await request.file();

      if (!data) {
        return reply.status(400).send({ error: 'No file uploaded' });
      }

      // Sent as a form field ahead of the file part in the multipart body (see APIService's
      // submitVerificationPhoto) — @fastify/multipart only exposes fields that arrived before
      // the file it's currently parsing, hence the field-ordering requirement on the client.
      const submittedPoseId = (data.fields.pose as { value?: unknown } | undefined)?.value;

      const user = await prisma.user.findUnique({
        where: { id: request.userId },
        select: { verificationPose: true, verificationPoseExpiresAt: true },
      });

      if (
        typeof submittedPoseId !== 'string' ||
        !user?.verificationPose ||
        submittedPoseId !== user.verificationPose ||
        !user.verificationPoseExpiresAt ||
        user.verificationPoseExpiresAt < new Date()
      ) {
        return reply.status(400).send({
          error: 'Your verification pose expired. Get a new one and retake the selfie.',
        });
      }

      const buffer = await data.toBuffer();

      const maxSize = parseInt(process.env.MAX_PHOTO_SIZE_MB || '10') * 1024 * 1024;
      if (buffer.length > maxSize) {
        return reply.status(400).send({ error: 'File too large' });
      }

      // Verification selfies aren't shown as a small grid thumbnail anywhere the way profile
      // photos are (see storage.ts's uploadPhoto comment) — just the one photo, shown at real
      // size — so the generated thumbnail isn't used here, only the full-size url.
      const { url: photoKey } = await uploadPhoto(buffer, request.userId!, true);

      await prisma.user.update({
        where: { id: request.userId },
        data: {
          verificationPhotoUrl: photoKey,
          verificationStatus: 'pending',
          verificationReviewedById: null,
          verificationReviewedAt: null,
        },
      });

      return reply.status(201).send({ message: 'Verification photo submitted for review' });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to submit verification photo' });
    }
  });

  // Own verification status
  fastify.get('/status', { preHandler: authenticate }, async (request, reply) => {
    try {
      const user = await prisma.user.findUnique({
        where: { id: request.userId },
        select: {
          isVerified: true,
          verificationStatus: true,
          verificationPhotoUrl: true,
          verificationReviewedAt: true,
        },
      });

      if (!user) {
        return reply.status(404).send({ error: 'User not found' });
      }

      return reply.send({
        isVerified: user.isVerified,
        status: user.verificationStatus,
        photoUrl: user.verificationPhotoUrl ? await getPresignedUrl(user.verificationPhotoUrl) : null,
        reviewedAt: user.verificationReviewedAt,
      });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to fetch verification status' });
    }
  });

  // Admin: queue of pending verification requests
  fastify.get('/admin', { preHandler: [authenticateAdmin, requirePermission('verification')] }, async (request, reply) => {
    try {
      const { status } = request.query as { status?: string };

      const users = await prisma.user.findMany({
        where: { verificationStatus: (status as any) || 'pending' },
        orderBy: { createdAt: 'asc' },
        select: {
          id: true,
          email: true,
          verificationStatus: true,
          verificationPhotoUrl: true,
          verificationPose: true,
          photos: {
            where: { moderationStatus: 'approved' },
            orderBy: { order: 'asc' },
            take: 3,
          },
        },
      });

      const requests = await Promise.all(
        users.map(async (u) => ({
          userId: u.id,
          email: u.email,
          status: u.verificationStatus,
          selfieUrl: u.verificationPhotoUrl ? await getPresignedUrl(u.verificationPhotoUrl) : null,
          // The pose the user was required to actually do for this submission — reviewers should
          // reject anything where the selfie doesn't show it, since that's the whole point (see
          // schema.prisma's User.verificationPose comment).
          expectedPose: findPoseLabel(u.verificationPose),
          profilePhotoUrls: await Promise.all(u.photos.map((p) => getPresignedUrl(p.url))),
        }))
      );

      return reply.send({ requests });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to fetch verification queue' });
    }
  });

  // Admin: approve/reject a verification request
  fastify.post('/admin/:userId/action', { preHandler: [authenticateAdmin, requirePermission('verification')] }, async (request, reply) => {
    try {
      const { userId } = request.params as { userId: string };
      const { action } = request.body as { action: 'approve' | 'reject' };

      if (action !== 'approve' && action !== 'reject') {
        return reply.status(400).send({ error: 'action must be "approve" or "reject"' });
      }

      const user = await prisma.user.findUnique({ where: { id: userId } });
      if (!user) {
        return reply.status(404).send({ error: 'User not found' });
      }

      await prisma.user.update({
        where: { id: userId },
        data: {
          isVerified: action === 'approve',
          verificationStatus: action === 'approve' ? 'approved' : 'rejected',
          verificationReviewedById: request.adminId,
          verificationReviewedAt: new Date(),
        },
      });

      return reply.send({ message: `Verification ${action}d` });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to act on verification request' });
    }
  });
}
