import { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { Sentry } from '../sentry';
import { zodErrorMessage } from '../utils/validation';

const diagnosticReportSchema = z.object({
  type: z.string().max(50),
  message: z.string().max(2000),
  stack: z.string().max(8000).optional(),
  platform: z.literal('ios'),
  appVersion: z.string().max(20).optional(),
  osVersion: z.string().max(20),
});

export default async function diagnosticsRoutes(fastify: FastifyInstance) {
  // No `authenticate` preHandler — a crash can happen while logged out (or before a session
  // ever existed), and the whole point is to still capture that. Rate-limited tighter than the
  // app-wide default since this is unauthenticated and easy to spam.
  fastify.post(
    '/report',
    { config: { rateLimit: { max: 20, timeWindow: 60000 } } },
    async (request, reply) => {
      try {
        const data = diagnosticReportSchema.parse(request.body);

        Sentry.captureException(new Error(`[iOS ${data.type}] ${data.message}`), {
          tags: { platform: data.platform, reportType: data.type },
          extra: { stack: data.stack, appVersion: data.appVersion, osVersion: data.osVersion },
        });

        return reply.send({ message: 'Report received' });
      } catch (error: any) {
        fastify.log.error(error);

        if (error.name === 'ZodError') {
          return reply.status(400).send({ error: zodErrorMessage(error) });
        }

        return reply.status(500).send({ error: 'Failed to record report' });
      }
    }
  );
}
