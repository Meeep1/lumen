import { FastifyRequest } from 'fastify';

declare module 'fastify' {
  interface FastifyRequest {
    userId?: string;
    /** Set by `authenticate` (which already looks the user up to check suspension status), so
     * `requireAdmin` can reuse it instead of running a second query. */
    userIsAdmin?: boolean;
  }
}

export interface AuthenticatedRequest extends FastifyRequest {
  userId: string;
}
