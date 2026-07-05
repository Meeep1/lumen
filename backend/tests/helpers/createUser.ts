import { FastifyInstance } from 'fastify';

let counter = 0;

/// Signs up, verifies (via the fixed dev-mode OTP — see utils/auth.ts's NODE_ENV guard, which
/// tests/setup.ts's NODE_ENV='test' also satisfies), and logs in a throwaway user in one call,
/// returning the access token and id every other test helper/assertion needs. `counter` keeps
/// concurrent-within-a-file test users from colliding on the unique email/phone constraints.
export async function createUser(
  app: FastifyInstance,
  overrides: Partial<{ email: string; phone: string; password: string }> = {}
): Promise<{ userId: string; accessToken: string; email: string }> {
  counter += 1;
  const email = overrides.email ?? `test-user-${counter}-${Date.now()}@example.com`;
  const phone = overrides.phone ?? `+1555${String(1000000 + counter).slice(0, 7)}`;
  const password = overrides.password ?? 'TestPass123!';

  const signupRes = await app.inject({
    method: 'POST',
    url: '/auth/signup',
    payload: {
      email,
      phone,
      password,
      dateOfBirth: '2000-01-01T00:00:00Z',
      genderIdentity: 'woman',
      femAttestationAccepted: true,
    },
  });
  if (signupRes.statusCode !== 200 && signupRes.statusCode !== 201) {
    throw new Error(`signup failed: ${signupRes.statusCode} ${signupRes.body}`);
  }

  const verifyRes = await app.inject({
    method: 'POST',
    url: '/auth/verify-otp',
    payload: { email, code: '123456' },
  });
  if (verifyRes.statusCode !== 200) {
    throw new Error(`verify-otp failed: ${verifyRes.statusCode} ${verifyRes.body}`);
  }
  const { accessToken, user } = verifyRes.json();

  return { userId: user.id, accessToken, email };
}
