import { FastifyRequest, FastifyReply } from 'fastify';

/// A second, outer gate in front of the admin panel — separate from (and in addition to) the
/// per-account `requireAdmin` JWT check every admin action already goes through. Without this,
/// anyone who found `/admin/` (a guessable, undocumented-but-discoverable path) could load the
/// real Lumen-branded admin login screen and start probing it, even though they could never
/// actually authenticate past it. This stops that at the door: a plain HTTP Basic Auth prompt,
/// shared across everyone who's allowed to know the admin panel exists at all, checked before
/// the static HTML/JS is even served or any `/admin-tools` route runs.
///
/// Fails closed if unconfigured — a missing `ADMIN_BASIC_AUTH_USER`/`PASSWORD` means the admin
/// panel is entirely unreachable rather than silently open, so a forgotten `.env` value in a new
/// environment can't accidentally expose it.
export async function requireBasicAuth(request: FastifyRequest, reply: FastifyReply) {
  const expectedUser = process.env.ADMIN_BASIC_AUTH_USER;
  const expectedPassword = process.env.ADMIN_BASIC_AUTH_PASSWORD;

  if (!expectedUser || !expectedPassword) {
    return reply.status(500).send({ error: 'Admin access is not configured on this server' });
  }

  const header = request.headers.authorization;
  if (!header || !header.startsWith('Basic ')) {
    return reply
      .header('WWW-Authenticate', 'Basic realm="Lumen Admin", charset="UTF-8"')
      .status(401)
      .send();
  }

  const decoded = Buffer.from(header.slice('Basic '.length), 'base64').toString('utf-8');
  const separatorIndex = decoded.indexOf(':');
  const user = separatorIndex === -1 ? decoded : decoded.slice(0, separatorIndex);
  const password = separatorIndex === -1 ? '' : decoded.slice(separatorIndex + 1);

  if (user !== expectedUser || password !== expectedPassword) {
    return reply
      .header('WWW-Authenticate', 'Basic realm="Lumen Admin", charset="UTF-8"')
      .status(401)
      .send();
  }
}
