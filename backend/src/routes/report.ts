import { FastifyInstance } from 'fastify';
import { prisma } from '../server';
import { authenticate, requireAdmin } from '../middleware/auth';
import { requireBasicAuth } from '../middleware/basicAuth';
import { reportSchema, zodErrorMessage } from '../utils/validation';

export default async function reportRoutes(fastify: FastifyInstance) {
  // Create a report
  // Spam-reporting is itself a harassment vector (mass-reporting someone to trigger review
  // burden or an automated action against them) — capped well above what a real user filing a
  // handful of legitimate reports in a sitting would ever hit.
  fastify.post('/', { preHandler: authenticate, config: { rateLimit: { max: 15, timeWindow: 60000 } } }, async (request, reply) => {
    try {
      const data = reportSchema.parse(request.body);

      // Check if reporting self
      if (request.userId === data.reportedId) {
        return reply.status(400).send({ error: 'Cannot report yourself' });
      }

      // Check if reported user exists
      const reportedUser = await prisma.user.findUnique({
        where: { id: data.reportedId },
      });

      if (!reportedUser) {
        return reply.status(404).send({ error: 'User not found' });
      }

      // Create report
      const report = await prisma.report.create({
        data: {
          reporterId: request.userId!,
          reportedId: data.reportedId,
          reason: data.reason,
          details: data.details,
        },
      });

      return reply.status(201).send({
        message: 'Report submitted. Our team will review it shortly.',
        reportId: report.id,
      });
    } catch (error: any) {
      fastify.log.error(error);
      
      if (error.name === 'ZodError') {
        return reply.status(400).send({ error: zodErrorMessage(error) });
      }
      
      return reply.status(500).send({ error: 'Failed to submit report' });
    }
  });

  // Admin: Get all reports
  // requireBasicAuth first — this file mixes the public POST / above with these admin-only
  // routes, so (unlike admin-tools.ts/moderation.ts, which are admin-only start to finish and
  // get the gate at the whole-file registration level in server.ts) it's added directly here
  // instead of wrapping the entire route file.
  fastify.get('/admin', { preHandler: [requireBasicAuth, authenticate, requireAdmin] }, async (request, reply) => {
    try {
      const { status } = request.query as { status?: string };

      const where: any = {};
      if (status) {
        where.status = status;
      }

      const reports = await prisma.report.findMany({
        where,
        include: {
          reporter: {
            select: {
              id: true,
              email: true,
              phone: true,
            },
          },
          reported: {
            select: {
              id: true,
              email: true,
              phone: true,
              genderIdentity: true,
              isSuspended: true,
            },
          },
        },
        orderBy: { createdAt: 'desc' },
      });

      return reply.send({ reports });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to fetch reports' });
    }
  });

  // Admin: Take action on a report
  fastify.post('/admin/:reportId/action', { preHandler: [requireBasicAuth, authenticate, requireAdmin] }, async (request, reply) => {
    try {
      const { reportId } = request.params as { reportId: string };
      const { action, suspensionDays } = request.body as {
        action: 'no_action' | 'warning' | 'temporary_suspension' | 'permanent_suspension';
        suspensionDays?: number;
      };

      const report = await prisma.report.findUnique({
        where: { id: reportId },
      });

      if (!report) {
        return reply.status(404).send({ error: 'Report not found' });
      }

      // Update report
      await prisma.report.update({
        where: { id: reportId },
        data: {
          status: 'actioned',
          actionTaken: action,
          reviewedById: request.userId,
          reviewedAt: new Date(),
        },
      });

      // Take action on reported user
      if (action === 'temporary_suspension' && suspensionDays) {
        const suspendedUntil = new Date();
        suspendedUntil.setDate(suspendedUntil.getDate() + suspensionDays);

        await prisma.user.update({
          where: { id: report.reportedId },
          data: {
            isSuspended: true,
            suspendedUntil,
            suspensionReason: `Reported for: ${report.reason}`,
          },
        });
      } else if (action === 'permanent_suspension') {
        await prisma.user.update({
          where: { id: report.reportedId },
          data: {
            isSuspended: true,
            suspendedUntil: null,
            suspensionReason: `Permanently suspended. Reason: ${report.reason}`,
            isActive: false,
          },
        });
      }

      return reply.send({ message: 'Action taken on report' });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to take action' });
    }
  });
}
