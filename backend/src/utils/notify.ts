import { prisma, redis } from '../server';
import { sendToUser } from '../socket/handlers';
import { sendPushNotification } from './apns';

type NotifyKind = 'new_match' | 'new_like';

const PREF_FIELD = {
  new_match: 'notifyNewMatch',
  new_like: 'notifyNewLike',
} as const;

// New likes get a per-recipient cooldown so ten likes in five minutes (very plausible for a
// popular profile) don't fire ten separate pushes — collapses to at most one notification per
// window; the like itself is still recorded and visible in Likes You regardless. Resolves
// ROADMAP.md's open question #3 pragmatically for v1 rather than building a full digest/queue
// system. Matches don't get this treatment — they're inherently rarer and each one matters.
const LIKE_NOTIFY_COOLDOWN_SECONDS = 15 * 60;

/// Shared by both the "new match" and "new like" trigger points: if the recipient is online
/// (has an open socket), send the live socket event so the app can react immediately (badge
/// refresh, in-app banner) instead of a push they don't need while already looking at the app.
/// If offline, send a real APNs push instead — silently no-ops if they have no push token yet
/// or APNs isn't configured (see sendPushNotification). Either path is skipped entirely if the
/// recipient has turned this notification kind off.
export async function notifyUser(
  userId: string,
  kind: NotifyKind,
  socketPayload: Record<string, unknown>,
  push: { title: string; body: string; data?: Record<string, unknown> }
) {
  const user = await prisma.user.findUnique({
    where: { id: userId },
    select: { notifyNewMatch: true, notifyNewLike: true, pushToken: true },
  });
  if (!user || !user[PREF_FIELD[kind]]) return;

  if (kind === 'new_like') {
    const cooldownKey = `like_notify_cooldown:${userId}`;
    const setIfAbsent = await redis.set(cooldownKey, '1', 'EX', LIKE_NOTIFY_COOLDOWN_SECONDS, 'NX');
    if (setIfAbsent === null) return; // already notified this user about a like recently
  }

  const isOnline = await redis.get(`user:${userId}:online`);
  if (isOnline) {
    sendToUser(userId, kind, socketPayload);
    return;
  }

  if (!user.pushToken) return;

  const result = await sendPushNotification(user.pushToken, push);
  if (!result.ok && result.reason === 'invalid-token') {
    await prisma.user.update({ where: { id: userId }, data: { pushToken: null, pushPlatform: null } });
  }
}
