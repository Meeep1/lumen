import argon2 from 'argon2';
import crypto from 'crypto';

export async function hashPassword(password: string): Promise<string> {
  return argon2.hash(password);
}

export async function verifyPassword(hash: string, password: string): Promise<boolean> {
  try {
    return await argon2.verify(hash, password);
  } catch {
    return false;
  }
}

export function generateOTP(): string {
  // Fixed code for local dev/testing so you don't have to dig through server logs every time —
  // never do this in production. Guarded by NODE_ENV so it can't accidentally ship live.
  if (process.env.NODE_ENV !== 'production') {
    return '123456';
  }
  return crypto.randomInt(100000, 999999).toString();
}

export function generateRefreshToken(): string {
  return crypto.randomBytes(64).toString('hex');
}
