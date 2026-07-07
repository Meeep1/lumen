import { FastifyInstance } from 'fastify';
import { prisma } from '../server';
import { authenticate } from '../middleware/auth';
import { authenticateAdmin, requirePermission } from '../middleware/adminAuth';
import { feedbackSchema, zodErrorMessage } from '../utils/validation';

export default async function feedbackRoutes(fastify: FastifyInstance) {
  // Submit feedback — a one-way "tell us something" box (see schema.prisma's Feedback comment),
  // not a support ticket with a reply loop. Rate-limited the same order of magnitude as reports:
  // generous for genuine use, capped well below anything spammy.
  fastify.post('/', { preHandler: authenticate, config: { rateLimit: { max: 10, timeWindow: 60000 } } }, async (request, reply) => {
    try {
      const data = feedbackSchema.parse(request.body);

      await prisma.feedback.create({
        data: { userId: request.userId!, message: data.message },
      });

      return reply.status(201).send({ message: 'Thanks for the feedback.' });
    } catch (error: any) {
      if (error.name === 'ZodError') {
        return reply.status(400).send({ error: zodErrorMessage(error) });
      }
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to submit feedback' });
    }
  });

  // Admin: most recent feedback first — reuses the `reports` permission rather than adding a
  // whole new permission slot for what's a single read-only list, same reasoning as admin-tools
  // routes that piggyback on an existing permission for a small, closely-related capability.
  fastify.get('/admin', { preHandler: [authenticateAdmin, requirePermission('reports')] }, async (request, reply) => {
    try {
      const feedback = await prisma.feedback.findMany({
        orderBy: { createdAt: 'desc' },
        take: 200,
        include: { user: { select: { email: true } } },
      });

      return reply.send({
        feedback: feedback.map((f) => ({
          id: f.id,
          userId: f.userId,
          email: f.user?.email ?? null,
          message: f.message,
          createdAt: f.createdAt,
        })),
      });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to fetch feedback' });
    }
  });
}
