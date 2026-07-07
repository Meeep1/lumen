import { z } from 'zod';

const MIN_AGE = parseInt(process.env.MIN_AGE || '18');

// Route handlers catch ZodError and need a single readable string to send back — the iOS
// client's ErrorResponse model expects `error: String`, not the raw Zod issue array, so sending
// the array directly (as every route used to) makes JSON decoding fail client-side and falls
// back to a generic "Server error: 400" that hides the actual validation reason.
export function zodErrorMessage(error: z.ZodError): string {
  return error.errors.map((e) => e.message).join(', ');
}

export const signupSchema = z.object({
  email: z.string().email('Invalid email address'),
  phone: z.string().min(10, 'Phone number must be at least 10 digits'),
  // Optional because an Apple sign-up has no password at all — Apple's identity token is the
  // entire authentication for that account. Every other requirement (phone/OTP, age, gender,
  // fem attestation) still applies the same either way; Apple only replaces the password step.
  password: z.string().min(8, 'Password must be at least 8 characters').optional(),
  appleIdentityToken: z.string().optional(),
  // Compares using UTC components throughout, not local-timezone getters — a midnight-UTC DOB
  // (the client sends dateOfBirth as an ISO string with a Z suffix) reads as the *previous
  // evening* in any server timezone behind UTC (confirmed: new Date('2008-07-05T00:00:00Z')
  // .getDate() returns 4, not 5, in US Eastern). That shifted someone's effective birthday
  // back by a day, which could let a 17-year-old sign up up to a day before actually turning
  // the minimum age. Mixing getUTC*() consistently for both dates removes the timezone entirely
  // from the comparison instead of relying on it happening to cancel out.
  dateOfBirth: z.string().refine((date) => {
    const birthDate = new Date(date);
    if (isNaN(birthDate.getTime())) return false;
    const today = new Date();

    let age = today.getUTCFullYear() - birthDate.getUTCFullYear();
    const monthDiff = today.getUTCMonth() - birthDate.getUTCMonth();
    if (monthDiff < 0 || (monthDiff === 0 && today.getUTCDate() < birthDate.getUTCDate())) {
      age--;
    }

    return age >= MIN_AGE;
  }, `Must be at least ${MIN_AGE} years old`),
  genderIdentity: z.enum(['woman', 'femboy', 'trans_woman', 'nonbinary_feminine', 'other']),
  genderIdentityOther: z.string().optional(),
  femAttestationAccepted: z.boolean().refine((val) => val === true, {
    message: 'You must confirm you identify as feminine or present as feminine',
  }),
}).refine((data) => data.password || data.appleIdentityToken, {
  message: 'Password is required unless signing up with Apple',
  path: ['password'],
});

export const verifyOTPSchema = z.object({
  email: z.string().email(),
  code: z.string().length(6, 'OTP must be 6 digits'),
});

export const resendOTPSchema = z.object({
  email: z.string().email(),
});

export const appleAuthSchema = z.object({
  identityToken: z.string(),
});

export const loginSchema = z.object({
  email: z.string().email(),
  password: z.string(),
});

export const refreshTokenSchema = z.object({
  refreshToken: z.string(),
});

// Preset prompt questions (Hinge-style) — kept in sync by hand with
// Lumen/Models/Models.swift's `PromptQuestion.allCases` on the iOS side.
export const PROMPT_QUESTIONS = [
  'A random fact I love is...',
  'My ideal Sunday...',
  'The way to win me over is...',
  "I'm weirdly competitive about...",
  'Two truths and a lie...',
  'My love language is...',
] as const;

export const updateProfileSchema = z.object({
  genderIdentity: z.enum(['woman', 'femboy', 'trans_woman', 'nonbinary_feminine', 'other']).optional(),
  genderIdentityOther: z.string().max(100).optional(),
  bio: z.string().max(500).optional(),
  pronouns: z.string().max(50).optional(),
  styleTags: z.array(z.string().max(30)).max(10).optional(),
  heightInches: z.number().int().min(48).max(96).optional(),
  jobTitle: z.string().max(100).optional(),
  school: z.string().max(100).optional(),
  prompt1Question: z.enum(PROMPT_QUESTIONS).optional(),
  prompt1Answer: z.string().max(300).optional(),
  prompt2Question: z.enum(PROMPT_QUESTIONS).optional(),
  prompt2Answer: z.string().max(300).optional(),
  prompt3Question: z.enum(PROMPT_QUESTIONS).optional(),
  prompt3Answer: z.string().max(300).optional(),
  latitude: z.number().min(-90).max(90).optional(),
  longitude: z.number().min(-180).max(180).optional(),
  cityDisplay: z.string().max(100).optional(),
  discoverable: z.boolean().optional(),
  notifyNewMatch: z.boolean().optional(),
  notifyNewMessage: z.boolean().optional(),
  notifyNewLike: z.boolean().optional(),
});

export const pushTokenSchema = z.object({
  token: z.string().min(1),
  platform: z.literal('ios'),
});

export const swipeSchema = z.object({
  swipedId: z.string().uuid(),
  direction: z.enum(['like', 'pass', 'super_like']),
  // Hinge-style targeted like: which specific photo or prompt (1 or 2) prompted the like,
  // plus an optional comment. Only meaningful when direction is 'like'/'super_like'.
  likedPhotoId: z.string().uuid().optional(),
  likedPromptNumber: z.union([z.literal(1), z.literal(2)]).optional(),
  message: z.string().max(300).optional(),
});

// Query string values always arrive as strings (or comma-joined strings for
// array-shaped filters), so this coerces/splits before validating.
export const discoveryFiltersSchema = z.object({
  minAge: z.coerce.number().min(MIN_AGE).optional(),
  maxAge: z.coerce.number().max(100).optional(),
  maxDistance: z.coerce.number().min(1).max(500).optional(), // in miles
  minHeightInches: z.coerce.number().int().min(48).max(96).optional(),
  maxHeightInches: z.coerce.number().int().min(48).max(96).optional(),
  verifiedOnly: z.coerce.boolean().optional(),
  genderIdentities: z
    .union([z.string(), z.array(z.string())])
    .transform((val) => (Array.isArray(val) ? val : val.split(',')))
    .optional(),
});

export const sendMessageSchema = z.object({
  content: z.string().max(2000).optional(),
  // Not `.url()` — every photo URL in this app (profile photos, chat images alike) is a
  // host-relative path from getPresignedUrl()/uploadChatImage() (e.g. "/uploads/chat/..."), and
  // the client always resolves it against its own baseURL via APIService.imageURL(for:). A
  // relative path correctly fails a `.url()` check, which would reject every real image message.
  imageUrl: z.string().min(1).optional(),
}).refine((data) => data.content || data.imageUrl, {
  message: 'Either content or imageUrl must be provided',
});

export const reportSchema = z.object({
  reportedId: z.string().uuid(),
  reason: z.enum([
    'harassment',
    'fake_profile',
    'misrepresenting_presentation',
    'inappropriate_content',
    'underage_suspicion',
    'other',
  ]),
  details: z.string().max(1000).optional(),
});

export const blockSchema = z.object({
  blockedId: z.string().uuid(),
});

export const feedbackSchema = z.object({
  message: z.string().trim().min(1).max(2000),
});
