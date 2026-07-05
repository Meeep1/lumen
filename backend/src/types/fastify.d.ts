import { FastifyRequest } from 'fastify';

declare module 'fastify' {
  interface FastifyRequest {
    userId?: string;
    /** Set by `authenticateAdmin` (middleware/adminAuth.ts) — the logged-in AdminUser's id,
     * distinct from `userId` above (regular app accounts and admin accounts are entirely
     * separate tables, see AdminUser in schema.prisma). */
    adminId?: string;
    /** Set by `authenticateAdmin`, so `requirePermission` doesn't need a second query. */
    adminPermissions?: string[];
    /** Set by `authenticateAdmin`. A super admin bypasses `adminPermissions` entirely. */
    adminIsSuperAdmin?: boolean;
  }
}

export interface AuthenticatedRequest extends FastifyRequest {
  userId: string;
}
