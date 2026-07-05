import { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { prisma } from '../server';
import { hashPassword, verifyPassword } from '../utils/auth';
import { zodErrorMessage } from '../utils/validation';
import { authenticateAdmin, requireSuperAdmin, ADMIN_PERMISSIONS } from '../middleware/adminAuth';
import { requireBasicAuth } from '../middleware/basicAuth';

const loginSchema = z.object({
  email: z.string().email(),
  password: z.string().min(1),
});

const createAdminSchema = z.object({
  email: z.string().email(),
  password: z.string().min(8),
  permissions: z.array(z.enum(ADMIN_PERMISSIONS)).default([]),
  isSuperAdmin: z.boolean().default(false),
});

const updateAdminSchema = z.object({
  permissions: z.array(z.enum(ADMIN_PERMISSIONS)).optional(),
  isSuperAdmin: z.boolean().optional(),
  isActive: z.boolean().optional(),
  password: z.string().min(8).optional(),
});

/// Admin-panel authentication and team management. Entirely separate from routes/auth.ts (the
/// dating app's own login) — see AdminUser in schema.prisma for why.
export default async function adminAuthRoutes(fastify: FastifyInstance) {
  // The only route in this file reachable without an admin Bearer token, so it's the only one
  // that can also carry requireBasicAuth (see server.ts's comment on why the other routes here
  // — and every other admin route file — deliberately don't).
  fastify.post('/login', { preHandler: requireBasicAuth, config: { rateLimit: { max: 10, timeWindow: 60000 } } }, async (request, reply) => {
    try {
      const data = loginSchema.parse(request.body);

      const admin = await prisma.adminUser.findUnique({ where: { email: data.email } });
      if (!admin || !admin.isActive) {
        return reply.status(401).send({ error: 'Invalid credentials' });
      }

      const validPassword = await verifyPassword(admin.passwordHash, data.password);
      if (!validPassword) {
        return reply.status(401).send({ error: 'Invalid credentials' });
      }

      await prisma.adminUser.update({ where: { id: admin.id }, data: { lastLoginAt: new Date() } });

      // Longer-lived than a user access token (15m) and no refresh flow — see AdminUser's own
      // comment in schema.prisma for why that's an acceptable tradeoff for a small internal team.
      const accessToken = fastify.jwt.sign({ adminId: admin.id, type: 'admin' }, { expiresIn: '12h' });

      return reply.send({
        accessToken,
        admin: {
          id: admin.id,
          email: admin.email,
          isSuperAdmin: admin.isSuperAdmin,
          permissions: admin.permissions,
        },
      });
    } catch (error: any) {
      fastify.log.error(error);
      if (error.name === 'ZodError') {
        return reply.status(400).send({ error: zodErrorMessage(error) });
      }
      return reply.status(500).send({ error: 'Login failed' });
    }
  });

  // Restores a session on page load (see public/admin/index.html's init()) — the login response
  // already has this same shape, this just re-derives it from the still-valid access token so a
  // reload doesn't need its own separate localStorage copy of permissions that could go stale if
  // a super admin changes them elsewhere.
  fastify.get('/me', { preHandler: authenticateAdmin }, async (request, reply) => {
    const admin = await prisma.adminUser.findUnique({ where: { id: request.adminId } });
    if (!admin) {
      return reply.status(404).send({ error: 'Not found' });
    }
    return reply.send({
      id: admin.id, email: admin.email, isSuperAdmin: admin.isSuperAdmin, permissions: admin.permissions,
    });
  });

  // Everything below manages the admin team itself — super admin only, so a regular moderator
  // can never grant themselves (or anyone else) more access than they were given.

  fastify.get('/team', { preHandler: [authenticateAdmin, requireSuperAdmin] }, async (request, reply) => {
    const admins = await prisma.adminUser.findMany({
      orderBy: { createdAt: 'asc' },
      select: {
        id: true, email: true, isSuperAdmin: true, permissions: true, isActive: true,
        createdAt: true, lastLoginAt: true,
      },
    });
    return reply.send({ admins, availablePermissions: ADMIN_PERMISSIONS });
  });

  fastify.post('/team', { preHandler: [authenticateAdmin, requireSuperAdmin] }, async (request, reply) => {
    try {
      const data = createAdminSchema.parse(request.body);

      const existing = await prisma.adminUser.findUnique({ where: { email: data.email } });
      if (existing) {
        return reply.status(400).send({ error: 'An admin with that email already exists' });
      }

      const passwordHash = await hashPassword(data.password);
      const admin = await prisma.adminUser.create({
        data: {
          email: data.email,
          passwordHash,
          permissions: data.permissions,
          isSuperAdmin: data.isSuperAdmin,
          createdById: request.adminId,
        },
      });

      return reply.status(201).send({
        id: admin.id, email: admin.email, isSuperAdmin: admin.isSuperAdmin, permissions: admin.permissions,
      });
    } catch (error: any) {
      fastify.log.error(error);
      if (error.name === 'ZodError') {
        return reply.status(400).send({ error: zodErrorMessage(error) });
      }
      return reply.status(500).send({ error: 'Failed to create admin' });
    }
  });

  fastify.patch('/team/:id', { preHandler: [authenticateAdmin, requireSuperAdmin] }, async (request, reply) => {
    try {
      const { id } = request.params as { id: string };
      const data = updateAdminSchema.parse(request.body);

      // Otherwise a super admin could lock themselves out entirely with no other super admin
      // left to undo it (or, in a single-admin team, permanently — nobody could ever log in
      // to fix it again).
      if (id === request.adminId && (data.isSuperAdmin === false || data.isActive === false)) {
        return reply.status(400).send({ error: "You can't revoke your own super admin access or deactivate yourself." });
      }

      const { password, ...rest } = data;
      const updateData: Record<string, unknown> = { ...rest };
      if (password) {
        updateData.passwordHash = await hashPassword(password);
      }

      const admin = await prisma.adminUser.update({ where: { id }, data: updateData });
      return reply.send({
        id: admin.id, email: admin.email, isSuperAdmin: admin.isSuperAdmin,
        permissions: admin.permissions, isActive: admin.isActive,
      });
    } catch (error: any) {
      fastify.log.error(error);
      if (error.name === 'ZodError') {
        return reply.status(400).send({ error: zodErrorMessage(error) });
      }
      return reply.status(500).send({ error: 'Failed to update admin' });
    }
  });

  fastify.delete('/team/:id', { preHandler: [authenticateAdmin, requireSuperAdmin] }, async (request, reply) => {
    const { id } = request.params as { id: string };
    if (id === request.adminId) {
      return reply.status(400).send({ error: "You can't delete your own account." });
    }

    try {
      await prisma.adminUser.delete({ where: { id } });
      return reply.status(204).send();
    } catch (error) {
      fastify.log.error(error);
      return reply.status(404).send({ error: 'Admin not found' });
    }
  });
}
