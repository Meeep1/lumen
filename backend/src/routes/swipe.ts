import { FastifyInstance } from 'fastify';
import { prisma } from '../server';
import { authenticate } from '../middleware/auth';
import { swipeSchema, zodErrorMessage } from '../utils/validation';
import { getPresignedUrl } from '../utils/storage';
import { calculateDistance } from '../utils/geo';
import { notifyUser } from '../utils/notify';
import { SEED_EMAIL_SUFFIX } from '../utils/testAccount';

export default async function swipeRoutes(fastify: FastifyInstance) {
  // Create a swipe
  // Generous enough for genuine rapid swiping (roughly one per second sustained) while still
  // putting a real ceiling on a bot trying to exhaust the discovery pool or scrape profile data
  // via repeated swipes.
  fastify.post('/', { preHandler: authenticate, config: { rateLimit: { max: 60, timeWindow: 60000 } } }, async (request, reply) => {
    try {
      const data = swipeSchema.parse(request.body);

      // Check if already swiped
      const existingSwipe = await prisma.swipe.findUnique({
        where: {
          swiperId_swipedId: {
            swiperId: request.userId!,
            swipedId: data.swipedId,
          },
        },
      });

      if (existingSwipe) {
        return reply.status(400).send({ error: 'Already swiped on this user' });
      }

      // Check if swiping on self
      if (request.userId === data.swipedId) {
        return reply.status(400).send({ error: 'Cannot swipe on yourself' });
      }

      // Check if blocked
      const blocked = await prisma.block.findFirst({
        where: {
          OR: [
            { blockerId: request.userId, blockedId: data.swipedId },
            { blockerId: data.swipedId, blockedId: request.userId },
          ],
        },
      });

      if (blocked) {
        return reply.status(400).send({ error: 'Cannot swipe on this user' });
      }

      // Create swipe
      await prisma.swipe.create({
        data: {
          swiperId: request.userId!,
          swipedId: data.swipedId,
          direction: data.direction,
          likedPhotoId: data.likedPhotoId,
          likedPromptNumber: data.likedPromptNumber,
          message: data.message,
        },
      });

      // Check for match (only on "like" or "super_like")
      let match = null;
      if (data.direction === 'like' || data.direction === 'super_like') {
        const reciprocalSwipe = await prisma.swipe.findFirst({
          where: {
            swiperId: data.swipedId,
            swipedId: request.userId,
            direction: { in: ['like', 'super_like'] },
          },
        });

        if (reciprocalSwipe) {
          // Create match
          const [userA, userB] = [request.userId!, data.swipedId].sort();
          
          match = await prisma.match.create({
            data: {
              userAId: userA,
              userBId: userB,
            },
            include: {
              userA: {
                select: {
                  id: true,
                  genderIdentity: true,
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
                  photos: {
                    where: { moderationStatus: 'approved' },
                    orderBy: { order: 'asc' },
                    take: 1,
                  },
                },
              },
            },
          });
        }
      }

      if (match) {
        const otherUserId = match.userAId === request.userId ? match.userBId : match.userAId;

        // Only the other participant needs telling — the requester already has the match
        // result in this very response.
        void notifyUser(
          otherUserId,
          'new_match',
          { matchId: match.id },
          { title: "It's a Match!", body: 'You have a new match on Lumen.', data: { matchId: match.id } }
        );

        return reply.send({
          matched: true,
          matchId: match.id,
          matchedUser: { id: otherUserId },
        });
      }

      if (data.direction === 'like' || data.direction === 'super_like') {
        void notifyUser(
          data.swipedId,
          'new_like',
          {},
          { title: 'New Like', body: 'Someone likes you on Lumen.' }
        );
      }

      return reply.send({ matched: false });
    } catch (error: any) {
      fastify.log.error(error);
      
      if (error.name === 'ZodError') {
        return reply.status(400).send({ error: zodErrorMessage(error) });
      }
      
      return reply.status(500).send({ error: 'Failed to process swipe' });
    }
  });

  // Undo your own most recent swipe — deliberately only the single most recent one (no history
  // of undos, no "undo twice in a row" support), and only if it hasn't already resulted in a
  // match: a match notifies the other person immediately (see notifyUser above), so silently
  // deleting one after the fact would leave them thinking they still have a match that's just
  // vanished from under them. A pass, or a like that hasn't been reciprocated yet, is safe to
  // undo since nobody else has seen any effect of it.
  fastify.delete('/last', { preHandler: authenticate }, async (request, reply) => {
    try {
      const lastSwipe = await prisma.swipe.findFirst({
        where: { swiperId: request.userId },
        orderBy: { createdAt: 'desc' },
      });

      if (!lastSwipe) {
        return reply.status(404).send({ error: 'Nothing to undo' });
      }

      const [userAId, userBId] = [request.userId!, lastSwipe.swipedId].sort();
      const existingMatch = await prisma.match.findUnique({
        where: { userAId_userBId: { userAId, userBId } },
      });

      if (existingMatch) {
        return reply.status(400).send({ error: "This already resulted in a match and can't be undone" });
      }

      await prisma.swipe.delete({ where: { id: lastSwipe.id } });

      return reply.send({ undone: true, swipedId: lastSwipe.swipedId });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to undo swipe' });
    }
  });

  // Get users who liked me
  fastify.get('/liked-me', { preHandler: authenticate }, async (request, reply) => {
    try {
      const currentUser = await prisma.user.findUnique({
        where: { id: request.userId },
        select: {
          latitude: true,
          longitude: true,
          prompt1Question: true,
          prompt1Answer: true,
          prompt2Question: true,
          prompt2Answer: true,
          isTestAccount: true,
        },
      });

      const likesReceived = await prisma.swipe.findMany({
        where: {
          swipedId: request.userId,
          direction: { in: ['like', 'super_like'] },
          // Seed profiles' pre-seeded likes (see testAccount.ts's resetTestAccount) and the
          // reviewer account itself exist only so the isTestAccount reviewer's Likes You is
          // never empty — every other real user should never see either mixed in with real likes.
          ...(currentUser?.isTestAccount
            ? {}
            : {
                swiper: {
                  email: { not: { endsWith: SEED_EMAIL_SUFFIX } },
                  isTestAccount: false,
                },
              }),
        },
        include: {
          swiper: {
            select: {
              id: true,
              genderIdentity: true,
              genderIdentityOther: true,
              bio: true,
              pronouns: true,
              styleTags: true,
              heightInches: true,
              jobTitle: true,
              school: true,
              prompt1Question: true,
              prompt1Answer: true,
              prompt2Question: true,
              prompt2Answer: true,
              cityDisplay: true,
              isVerified: true,
              dateOfBirth: true,
              latitude: true,
              longitude: true,
              photos: {
                where: { moderationStatus: 'approved' },
                orderBy: { order: 'asc' },
                take: 1,
              },
            },
          },
        },
        orderBy: { createdAt: 'desc' },
      });

      // Filter out users I've already swiped on
      const mySwipes = await prisma.swipe.findMany({
        where: { swiperId: request.userId },
        select: { swipedId: true },
      });

      const swipedIds = new Set(mySwipes.map((s) => s.swipedId));

      const unswipedLikes = likesReceived.filter(
        (like) => !swipedIds.has(like.swiperId)
      );

      const profiles = await Promise.all(
        unswipedLikes.map(async (like) => {
          const distance =
            currentUser?.latitude != null &&
            currentUser?.longitude != null &&
            like.swiper.latitude != null &&
            like.swiper.longitude != null
              ? Math.round(
                  calculateDistance(
                    currentUser.latitude,
                    currentUser.longitude,
                    like.swiper.latitude,
                    like.swiper.longitude
                  )
                )
              : 0;

          const primaryPhoto = like.swiper.photos[0]
            ? await getPresignedUrl(like.swiper.photos[0].url)
            : null;

          // Resolve what was specifically liked — a photo (belongs to the current user,
          // the recipient) or one of the current user's own prompts.
          let likedPhotoUrl: string | null = null;
          if (like.likedPhotoId) {
            const likedPhoto = await prisma.photo.findUnique({ where: { id: like.likedPhotoId } });
            if (likedPhoto) likedPhotoUrl = await getPresignedUrl(likedPhoto.url);
          }

          let likedPromptQuestion: string | null = null;
          let likedPromptAnswer: string | null = null;
          if (like.likedPromptNumber === 1) {
            likedPromptQuestion = currentUser?.prompt1Question ?? null;
            likedPromptAnswer = currentUser?.prompt1Answer ?? null;
          } else if (like.likedPromptNumber === 2) {
            likedPromptQuestion = currentUser?.prompt2Question ?? null;
            likedPromptAnswer = currentUser?.prompt2Answer ?? null;
          }

          return {
            id: like.swiper.id,
            age: calculateAge(like.swiper.dateOfBirth),
            genderIdentity: like.swiper.genderIdentity,
            genderIdentityOther: like.swiper.genderIdentityOther,
            bio: like.swiper.bio,
            pronouns: like.swiper.pronouns,
            styleTags: like.swiper.styleTags,
            heightInches: like.swiper.heightInches,
            jobTitle: like.swiper.jobTitle,
            school: like.swiper.school,
            prompt1Question: like.swiper.prompt1Question,
            prompt1Answer: like.swiper.prompt1Answer,
            prompt2Question: like.swiper.prompt2Question,
            prompt2Answer: like.swiper.prompt2Answer,
            cityDisplay: like.swiper.cityDisplay,
            isVerified: like.swiper.isVerified,
            distance,
            primaryPhoto,
            likedPhotoUrl,
            likedPromptQuestion,
            likedPromptAnswer,
            message: like.message,
            likedAt: like.createdAt,
          };
        })
      );

      return reply.send({ profiles });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to fetch likes' });
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
