import { FastifyRequest, FastifyReply } from 'fastify';
import { prisma } from '../server';

/// Every distinct admin-panel capability that can be granted independently. Kept as a flat list
/// (not nested/hierarchical) since the admin panel itself is just four sections — see
/// routes/admin-auth.ts (team management, super-admin only) and each section's own route file.
export const ADMIN_PERMISSIONS = ['moderation', 'reports', 'verification', 'testTools'] as const;
export type AdminPermission = (typeof ADMIN_PERMISSIONS)[number];

/// Verifies the JWT was issued to an AdminUser, not a regular User — both share the same JWT
/// secret (no reason to run two), so the `type: 'admin'` claim (set at login, see
/// routes/admin-auth.ts) is what tells them apart. A regular user's access token has no such
/// claim and is rejected here even though it would pass `request.jwtVerify()` on its own.
export async function authenticateAdmin(request: FastifyRequest, reply: FastifyReply) {
  try {
    await request.jwtVerify();
    const payload = request.user as { adminId?: string; type?: string };

    if (payload.type !== 'admin' || !payload.adminId) {
      return reply.status(401).send({ error: 'Unauthorized' });
    }

    const admin = await prisma.adminUser.findUnique({ where: { id: payload.adminId } });
    if (!admin || !admin.isActive) {
      return reply.status(401).send({ error: 'Unauthorized' });
    }

    request.adminId = admin.id;
    request.adminPermissions = admin.permissions;
    request.adminIsSuperAdmin = admin.isSuperAdmin;
  } catch (err) {
    reply.status(401).send({ error: 'Unauthorized' });
  }
}

/// Chain after `authenticateAdmin`, which already fetched permissions — no extra query needed
/// here. A super admin implicitly has every permission, so it's checked first. Accepts more than
/// one permission for the handful of routes shared across sections (e.g. admin-tools.ts's
/// "View Profile" modal is used by both the Reports and Photos tabs) — any one of them is enough.
export function requirePermission(...permissions: AdminPermission[]) {
  return async function (request: FastifyRequest, reply: FastifyReply) {
    if (request.adminIsSuperAdmin) return;
    const hasAny = permissions.some((p) => request.adminPermissions?.includes(p));
    if (!hasAny) {
      reply.status(403).send({ error: `Missing permission: ${permissions.join(' or ')}` });
    }
  };
}

/// Managing other admins (routes/admin-auth.ts's /team routes) is its own super-admin-only gate,
/// deliberately not just another entry in ADMIN_PERMISSIONS — granting someone the ability to
/// create/edit admin accounts is equivalent to granting them every other permission anyway
/// (they could just grant themselves the rest), so it isn't something a non-super-admin should
/// ever be able to hold piecemeal.
export async function requireSuperAdmin(request: FastifyRequest, reply: FastifyReply) {
  if (!request.adminIsSuperAdmin) {
    reply.status(403).send({ error: 'Super admin access required' });
  }
}
