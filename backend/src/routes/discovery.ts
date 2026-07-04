import { FastifyInstance } from 'fastify';
import { prisma } from '../server';
import { authenticate } from '../middleware/auth';
import { discoveryFiltersSchema, zodErrorMessage } from '../utils/validation';
import { getPresignedUrl } from '../utils/storage';
import { calculateDistance } from '../utils/geo';

export default async function discoveryRoutes(fastify: FastifyInstance) {
  fastify.get('/stack', { preHandler: authenticate }, async (request, reply) => {
    try {
      const filters = discoveryFiltersSchema.parse(request.query);

      const currentUser = await prisma.user.findUnique({
        where: { id: request.userId },
      });

      if (!currentUser || !currentUser.latitude || !currentUser.longitude) {
        return reply.status(400).send({
          error: 'Location required. Please update your profile with location.',
        });
      }

      // Calculate age from dateOfBirth
      const minAge = filters.minAge || 18;
      const maxAge = filters.maxAge || 100;
      const maxDistance = filters.maxDistance || 50; // miles

      const minBirthDate = new Date();
      minBirthDate.setFullYear(minBirthDate.getFullYear() - maxAge - 1);
      
      const maxBirthDate = new Date();
      maxBirthDate.setFullYear(maxBirthDate.getFullYear() - minAge);

      // Get blocked user IDs
      const blocks = await prisma.block.findMany({
        where: {
          OR: [
            { blockerId: request.userId },
            { blockedId: request.userId },
          ],
        },
        select: {
          blockerId: true,
          blockedId: true,
        },
      });

      const blockedUserIds = new Set(
        blocks.flatMap((b) => [b.blockerId, b.blockedId])
      );
      blockedUserIds.delete(request.userId!);

      // Get already swiped user IDs
      const swipes = await prisma.swipe.findMany({
        where: { swiperId: request.userId },
        select: { swipedId: true },
      });

      const swipedUserIds = new Set(swipes.map((s) => s.swipedId));

      // Build where clause
      const whereClause: any = {
        id: {
          not: request.userId,
          notIn: [...blockedUserIds, ...swipedUserIds],
        },
        isActive: true,
        discoverable: true,
        isSuspended: false,
        dateOfBirth: {
          gte: minBirthDate,
          lte: maxBirthDate,
        },
        latitude: { not: null },
        longitude: { not: null },
      };

      // Apply gender identity filter if specified
      if (filters.genderIdentities && filters.genderIdentities.length > 0) {
        whereClause.genderIdentity = { in: filters.genderIdentities };
      }

      if (filters.verifiedOnly) {
        whereClause.isVerified = true;
      }

      if (filters.minHeightInches != null || filters.maxHeightInches != null) {
        whereClause.heightInches = {
          ...(filters.minHeightInches != null ? { gte: filters.minHeightInches } : {}),
          ...(filters.maxHeightInches != null ? { lte: filters.maxHeightInches } : {}),
        };
      }

      // Fetch potential matches
      let candidates = await prisma.user.findMany({
        where: whereClause,
        include: {
          photos: {
            where: { moderationStatus: 'approved' },
            orderBy: { order: 'asc' },
          },
        },
        take: 100, // Fetch more than needed, will filter by distance
      });

      // Filter by distance
      candidates = candidates.filter((candidate) => {
        if (!candidate.latitude || !candidate.longitude) return false;
        
        const distance = calculateDistance(
          currentUser.latitude!,
          currentUser.longitude!,
          candidate.latitude,
          candidate.longitude
        );
        
        return distance <= maxDistance;
      });

      // Sort: verified first, then recently active, then random
      const sortedCandidates = candidates.sort((a, b) => {
        if (a.isVerified !== b.isVerified) {
          return a.isVerified ? -1 : 1;
        }
        
        const aRecency = a.lastActiveAt.getTime();
        const bRecency = b.lastActiveAt.getTime();
        
        if (Math.abs(aRecency - bRecency) > 24 * 60 * 60 * 1000) {
          return bRecency - aRecency;
        }
        
        return Math.random() - 0.5;
      });

      // Limit to 20 profiles
      const limitedCandidates = sortedCandidates.slice(0, 20);

      // Format response
      const profiles = await Promise.all(
        limitedCandidates.map(async (user) => {
          const distance = calculateDistance(
            currentUser.latitude!,
            currentUser.longitude!,
            user.latitude!,
            user.longitude!
          );

          const photos = await Promise.all(
            user.photos.map(async (photo) => ({
              id: photo.id,
              url: await getPresignedUrl(photo.url),
              order: photo.order,
            }))
          );

          return {
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
            distance: Math.round(distance),
            photos,
            primaryPhoto: photos[0]?.url ?? null,
          };
        })
      );

      return reply.send({ profiles });
    } catch (error: any) {
      fastify.log.error(error);
      
      if (error.name === 'ZodError') {
        return reply.status(400).send({ error: zodErrorMessage(error) });
      }
      
      return reply.status(500).send({ error: 'Failed to fetch discovery stack' });
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
