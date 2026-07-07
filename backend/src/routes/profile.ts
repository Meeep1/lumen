import { FastifyInstance } from 'fastify';
import { prisma } from '../server';
import { authenticate } from '../middleware/auth';
import { updateProfileSchema, pushTokenSchema, zodErrorMessage } from '../utils/validation';
import { uploadPhoto, deletePhoto, getPresignedUrl } from '../utils/storage';
import { relocateSeedProfilesNear } from '../utils/testAccount';
import { photoModerationQueue } from '../queue';

export default async function profileRoutes(fastify: FastifyInstance) {
  // Get own profile
  fastify.get('/me', { preHandler: authenticate }, async (request, reply) => {
    try {
      const user = await prisma.user.findUnique({
        where: { id: request.userId },
        include: {
          // Unlike every other photo query in this file (discovery, other-user profiles),
          // this one is the owner looking at their own profile — they should see pending/
          // rejected photos too (with status so the UI can show why), not have uploads
          // silently vanish until a human approves them. Only other users' views filter to
          // moderationStatus: 'approved'.
          photos: {
            orderBy: { order: 'asc' },
          },
        },
      });

      if (!user) {
        return reply.status(404).send({ error: 'User not found' });
      }

      // Get presigned URLs for photos
      const photosWithUrls = await Promise.all(
        user.photos.map(async (photo) => ({
          id: photo.id,
          url: await getPresignedUrl(photo.url),
          // Nullable — a photo uploaded before thumbnailUrl existed has none, so this falls
          // back to the same full-size url rather than a broken link.
          thumbnailUrl: photo.thumbnailUrl ? await getPresignedUrl(photo.thumbnailUrl) : await getPresignedUrl(photo.url),
          order: photo.order,
          moderationStatus: photo.moderationStatus,
          appealStatus: photo.appealStatus,
          appealMessage: photo.appealMessage,
          // A rejected photo is only appealable if no human has looked at it yet — auto-reject
          // (upload or rescan) leaves rejectedByAdminId null; a manual reject or a denied
          // appeal both set it, since either one already was a human's second look.
          canAppeal: photo.moderationStatus === 'rejected' && !photo.rejectedByAdminId,
        }))
      );

      return reply.send({
        id: user.id,
        email: user.email,
        phone: user.phone,
        dateOfBirth: user.dateOfBirth,
        age: calculateAge(user.dateOfBirth),
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
        latitude: user.latitude,
        longitude: user.longitude,
        cityDisplay: user.cityDisplay,
        isVerified: user.isVerified,
        discoverable: user.discoverable,
        notifyNewMatch: user.notifyNewMatch,
        notifyNewMessage: user.notifyNewMessage,
        notifyNewLike: user.notifyNewLike,
        photos: photosWithUrls,
      });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to fetch profile' });
    }
  });

  // Get another user's profile
  fastify.get('/:userId', { preHandler: authenticate }, async (request, reply) => {
    try {
      const { userId } = request.params as { userId: string };

      // Check if blocked
      const blocked = await prisma.block.findFirst({
        where: {
          OR: [
            { blockerId: request.userId, blockedId: userId },
            { blockerId: userId, blockedId: request.userId },
          ],
        },
      });

      if (blocked) {
        return reply.status(404).send({ error: 'User not found' });
      }

      const user = await prisma.user.findUnique({
        where: { id: userId },
        include: {
          photos: {
            where: { moderationStatus: 'approved' },
            orderBy: { order: 'asc' },
          },
        },
      });

      if (!user || !user.isActive || !user.discoverable) {
        return reply.status(404).send({ error: 'User not found' });
      }

      const photosWithUrls = await Promise.all(
        user.photos.map(async (photo) => ({
          id: photo.id,
          url: await getPresignedUrl(photo.url),
          order: photo.order,
        }))
      );

      return reply.send({
        id: user.id,
        age: calculateAge(user.dateOfBirth),
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
        cityDisplay: user.cityDisplay,
        isVerified: user.isVerified,
        photos: photosWithUrls,
      });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to fetch profile' });
    }
  });

  // Update profile
  fastify.patch('/me', { preHandler: authenticate }, async (request, reply) => {
    try {
      const data = updateProfileSchema.parse(request.body);

      // Keep the tag catalog in sync so new tags become discoverable/autocompletable
      // (the user's own tags stay denormalized on User.styleTags for fast reads).
      if (data.styleTags && data.styleTags.length > 0) {
        await Promise.all(
          data.styleTags.map((name) =>
            prisma.tag.upsert({
              where: { name },
              create: { name },
              update: {},
            })
          )
        );
      }

      const user = await prisma.user.update({
        where: { id: request.userId },
        data: {
          ...data,
          lastActiveAt: new Date(),
        },
      });

      // The test account's location is wiped on every login reset (see resetTestAccount) and
      // set fresh during onboarding — re-anchor the seed profiles nearby right when that
      // happens, since a reviewer could be testing from anywhere and a fixed seed location
      // would mean Discovery/Likes You come up empty outside that one radius.
      if (user.isTestAccount && data.latitude != null && data.longitude != null) {
        await relocateSeedProfilesNear(prisma, data.latitude, data.longitude, user.cityDisplay);
      }

      return reply.send({
        message: 'Profile updated',
        profile: {
          bio: user.bio,
          pronouns: user.pronouns,
          styleTags: user.styleTags,
          heightInches: user.heightInches,
          latitude: user.latitude,
          longitude: user.longitude,
          cityDisplay: user.cityDisplay,
          discoverable: user.discoverable,
          notifyNewMatch: user.notifyNewMatch,
          notifyNewMessage: user.notifyNewMessage,
          notifyNewLike: user.notifyNewLike,
        },
      });
    } catch (error: any) {
      fastify.log.error(error);

      if (error.name === 'ZodError') {
        return reply.status(400).send({ error: zodErrorMessage(error) });
      }

      return reply.status(500).send({ error: 'Failed to update profile' });
    }
  });

  // Register (or replace) this device's APNs token — called after the client successfully
  // registers for remote notifications. Re-registering with a new token (reinstall, token
  // rotation) just overwrites the old one; there's only ever one active token per user since
  // this app doesn't support being logged into multiple devices concurrently.
  fastify.post('/push-token', { preHandler: authenticate }, async (request, reply) => {
    try {
      const data = pushTokenSchema.parse(request.body);

      await prisma.user.update({
        where: { id: request.userId },
        data: { pushToken: data.token, pushPlatform: data.platform },
      });

      return reply.send({ message: 'Push token registered' });
    } catch (error: any) {
      fastify.log.error(error);

      if (error.name === 'ZodError') {
        return reply.status(400).send({ error: zodErrorMessage(error) });
      }

      return reply.status(500).send({ error: 'Failed to register push token' });
    }
  });

  // Records one "user reached this onboarding step" event (see OnboardingView.swift's
  // advance()/finish()) — self-hosted funnel tracking, not a third-party analytics SDK (see
  // OnboardingEvent's own comment in schema.prisma for why). Deliberately fire-and-forget from
  // the client's side and forgiving here: a step name typo or a missed event should never be
  // something a user notices, so this fails soft (200 even on most edge cases) rather than
  // surfacing errors for what's ultimately just internal instrumentation.
  fastify.post('/onboarding-event', { preHandler: authenticate }, async (request, reply) => {
    try {
      const { step } = request.body as { step?: string };
      if (!step || typeof step !== 'string' || step.length > 50) {
        return reply.status(400).send({ error: 'Invalid step' });
      }

      await prisma.onboardingEvent.create({
        data: { userId: request.userId!, step },
      });

      return reply.status(201).send({ recorded: true });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to record event' });
    }
  });

  // Upload photo
  fastify.post('/photos', { preHandler: authenticate }, async (request, reply) => {
    try {
      const data = await request.file();
      
      if (!data) {
        return reply.status(400).send({ error: 'No file uploaded' });
      }

      const buffer = await data.toBuffer();
      
      // Check file size (max 10MB)
      const maxSize = parseInt(process.env.MAX_PHOTO_SIZE_MB || '10') * 1024 * 1024;
      if (buffer.length > maxSize) {
        return reply.status(400).send({ error: 'File too large' });
      }

      // Check photo count
      const photoCount = await prisma.photo.count({
        where: { userId: request.userId },
      });

      const maxPhotos = parseInt(process.env.MAX_PHOTOS_PER_USER || '6');
      if (photoCount >= maxPhotos) {
        return reply.status(400).send({ error: `Maximum ${maxPhotos} photos allowed` });
      }

      // Upload to disk (or S3 in production)
      const { url: photoKey, thumbnailUrl: thumbnailKey } = await uploadPhoto(buffer, request.userId!);

      // Save to database — moderationStatus defaults to 'pending' (see schema.prisma). The
      // actual NSFWJS classification happens off-request now (see queue.ts/worker.ts): it's
      // 5-12s of blocking CPU work, and doing it inline here used to stall every *other* user's
      // requests for that entire window on every single upload, since Node's event loop is
      // single-threaded. The client already renders 'pending' as "Under review" and refreshes
      // on its own; a `photo_reviewed` socket event fires once the worker reaches a final
      // approved/rejected verdict (see socket/handlers.ts's photo-reviewed subscription).
      const photo = await prisma.photo.create({
        data: {
          userId: request.userId!,
          url: photoKey,
          thumbnailUrl: thumbnailKey,
          order: photoCount,
        },
      });

      await photoModerationQueue.add('moderate', { photoId: photo.id });

      return reply.status(201).send({
        id: photo.id,
        url: await getPresignedUrl(photoKey),
        thumbnailUrl: await getPresignedUrl(thumbnailKey),
        order: photo.order,
        moderationStatus: photo.moderationStatus,
      });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to upload photo' });
    }
  });

  // Delete photo
  fastify.delete('/photos/:photoId', { preHandler: authenticate }, async (request, reply) => {
    try {
      const { photoId } = request.params as { photoId: string };

      const photo = await prisma.photo.findUnique({
        where: { id: photoId },
      });

      if (!photo) {
        return reply.status(404).send({ error: 'Photo not found' });
      }

      if (photo.userId !== request.userId) {
        return reply.status(403).send({ error: 'Unauthorized' });
      }

      // Delete from S3
      await deletePhoto(photo.url);
      if (photo.thumbnailUrl) await deletePhoto(photo.thumbnailUrl);

      // Delete from database
      await prisma.photo.delete({
        where: { id: photoId },
      });

      // Reorder remaining photos
      await prisma.photo.updateMany({
        where: {
          userId: request.userId,
          order: { gt: photo.order },
        },
        data: {
          order: { decrement: 1 },
        },
      });

      return reply.send({ message: 'Photo deleted' });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to delete photo' });
    }
  });

  // Appeal a rejected photo — rejected photos (auto or admin) are kept, not deleted, specifically
  // so this has something to review (see routes/moderation.ts). One pending appeal at a time;
  // a denied appeal can be resubmitted (e.g. with more context in the message) but an already-
  // pending one can't be filed again on top of itself.
  fastify.post('/photos/:photoId/appeal', { preHandler: authenticate }, async (request, reply) => {
    try {
      const { photoId } = request.params as { photoId: string };
      const { message } = request.body as { message?: string };

      const photo = await prisma.photo.findUnique({ where: { id: photoId } });
      if (!photo) {
        return reply.status(404).send({ error: 'Photo not found' });
      }
      if (photo.userId !== request.userId) {
        return reply.status(403).send({ error: 'Unauthorized' });
      }
      if (photo.moderationStatus !== 'rejected') {
        return reply.status(400).send({ error: 'Only a rejected photo can be appealed' });
      }
      if (photo.rejectedByAdminId) {
        // A human already made this call (manual reject, or a previously denied appeal) —
        // that already was the second look an appeal exists to get.
        return reply.status(400).send({ error: 'This photo was already reviewed by a moderator and can\'t be appealed' });
      }
      if (photo.appealStatus === 'pending') {
        return reply.status(400).send({ error: 'This photo already has a pending appeal' });
      }

      await prisma.photo.update({
        where: { id: photoId },
        data: {
          appealStatus: 'pending',
          appealMessage: message?.trim() || null,
          appealCreatedAt: new Date(),
          appealReviewedById: null,
          appealReviewedAt: null,
        },
      });

      return reply.status(201).send({ message: 'Appeal submitted' });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to submit appeal' });
    }
  });

  // Reorder photos
  fastify.put('/photos/reorder', { preHandler: authenticate }, async (request, reply) => {
    try {
      const { photoIds } = request.body as { photoIds: string[] };

      // Verify all photos belong to user
      const photos = await prisma.photo.findMany({
        where: {
          id: { in: photoIds },
          userId: request.userId,
        },
      });

      if (photos.length !== photoIds.length) {
        return reply.status(400).send({ error: 'Invalid photo IDs' });
      }

      // Update orders
      await Promise.all(
        photoIds.map((id, index) =>
          prisma.photo.update({
            where: { id },
            data: { order: index },
          })
        )
      );

      return reply.send({ message: 'Photos reordered' });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to reorder photos' });
    }
  });
}

// UTC-consistent for the same reason as signupSchema's dateOfBirth check in validation.ts —
// mixing local-timezone getters with a UTC-stored timestamp can shift the effective day by one.
function calculateAge(dateOfBirth: Date): number {
  const today = new Date();
  let age = today.getUTCFullYear() - dateOfBirth.getUTCFullYear();
  const monthDiff = today.getUTCMonth() - dateOfBirth.getUTCMonth();

  if (monthDiff < 0 || (monthDiff === 0 && today.getUTCDate() < dateOfBirth.getUTCDate())) {
    age--;
  }

  return age;
}
