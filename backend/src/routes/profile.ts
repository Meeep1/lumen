import { FastifyInstance } from 'fastify';
import { prisma } from '../server';
import { authenticate } from '../middleware/auth';
import { updateProfileSchema, zodErrorMessage } from '../utils/validation';
import { uploadPhoto, deletePhoto, moderateImage, getPresignedUrl } from '../utils/storage';

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
          order: photo.order,
          moderationStatus: photo.moderationStatus,
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

      // Moderate image
      const moderation = await moderateImage(buffer);

      // Upload to S3
      const photoKey = await uploadPhoto(buffer, request.userId!);

      // Save to database
      const photo = await prisma.photo.create({
        data: {
          userId: request.userId!,
          url: photoKey,
          order: photoCount,
          moderationStatus: moderation.status,
          moderationLabels: moderation.labels,
        },
      });

      return reply.status(201).send({
        id: photo.id,
        url: await getPresignedUrl(photoKey),
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

function calculateAge(dateOfBirth: Date): number {
  const today = new Date();
  let age = today.getFullYear() - dateOfBirth.getFullYear();
  const monthDiff = today.getMonth() - dateOfBirth.getMonth();
  
  if (monthDiff < 0 || (monthDiff === 0 && today.getDate() < dateOfBirth.getDate())) {
    age--;
  }
  
  return age;
}
