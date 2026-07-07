import { prisma } from '../server';

/// Records a sensitive admin read (viewing a profile, a chat, the user directory) — see
/// AdminAuditLog's own schema.prisma comment for why this exists. Swallows its own errors (just
/// logs to console) rather than propagating — a failed audit write is worth knowing about, but
/// isn't a reason to fail the admin's actual request, which every call site would otherwise need
/// to remember to guard against individually.
export async function logAdminView(
  adminId: string,
  adminEmail: string,
  action: string,
  targetUserId?: string,
  detail?: string
): Promise<void> {
  try {
    await prisma.adminAuditLog.create({
      data: { adminId, adminEmail, action, targetUserId, detail },
    });
  } catch (error) {
    console.error('Failed to write admin audit log:', error);
  }
}
