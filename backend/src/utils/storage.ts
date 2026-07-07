// LOCAL DEVELOPMENT MODE
// Photos are stored on disk instead of S3
// Photo moderation runs for real (see moderateImage below) via a local NSFW model — no AWS

import crypto from 'crypto';
import fs from 'fs';
import path from 'path';
// @tensorflow/tfjs-node, not plain @tensorflow/tfjs — same API, but backed by compiled native
// TensorFlow (a prebuilt binary fetched at install time) instead of a pure-JS/CPU backend.
// Benchmarked directly against this exact model+code path: ~9.7s/photo on plain tfjs vs. ~54ms
// on tfjs-node — about 180x, with byte-identical predictions (confirmed on both this project's
// dev Mac, arm64, and the linux x64 production server). nsfwjs only declares `@tensorflow/tfjs`
// as a peerDependency rather than bundling its own copy, so it operates against whatever backend
// this import registers as active in the shared global TF engine — no nsfwjs-side changes
// needed. This is very likely the real fix for the BullMQ "Missing lock"/"stalled" errors worked
// around in worker.ts's lockDuration/stalledInterval: those exist because classification used to
// block this process's event loop long enough to delay BullMQ's own internal timers, and that's
// far less likely at ~54ms than it was at ~9.7s. Left the generous lockDuration/stalledInterval
// in place anyway as harmless headroom, not tied back down now that the root cause has shrunk.
import * as tf from '@tensorflow/tfjs-node';
import * as nsfwjs from 'nsfwjs';
import sharp from 'sharp';

// Create uploads directory if it doesn't exist
const UPLOADS_DIR = path.join(__dirname, '../../uploads');
if (!fs.existsSync(UPLOADS_DIR)) {
  fs.mkdirSync(UPLOADS_DIR, { recursive: true });
}

export async function uploadPhoto(
  buffer: Buffer,
  userId: string,
  isVerification: boolean = false
): Promise<{ url: string; thumbnailUrl: string }> {
  // Create user-specific directory
  const userDir = path.join(UPLOADS_DIR, isVerification ? 'verification' : 'photos', userId);
  if (!fs.existsSync(userDir)) {
    fs.mkdirSync(userDir, { recursive: true });
  }

  // Generate unique filename
  const id = crypto.randomUUID();
  const filename = `${id}.jpg`;
  const filepath = path.join(userDir, filename);

  // Normalize the original before writing it, rather than storing the raw upload as-is:
  //   - `.rotate()` with no args auto-orients from the EXIF tag and then strips it. A phone
  //     photo is very often stored as landscape pixel data plus a "rotate 90 to display" EXIF
  //     flag — a client that respects EXIF (UIImage does) shows it correctly, but `sharp`
  //     resize operations ignore EXIF unless told to auto-orient first, so anything built from
  //     the raw buffer (the thumbnail below, moderateImage()'s own resize) came out sideways
  //     for exactly the photos where this mattered. Normalizing once here, rather than adding
  //     `.rotate()` to every separate consumer, fixes it everywhere at once.
  //   - Capping the long edge at 1600px is plenty sharp on any real device (a 3x-retina phone
  //     at typical screen width needs well under that) but meaningfully shrinks what a modern
  //     phone photo actually uploads at (often 3000-4000px+) — the same "why load more than
  //     will ever be shown" reasoning as the thumbnail, just for the sizes that do need to be
  //     shown large (a Discovery card, a full profile view).
  const normalizedBuffer = await sharp(buffer)
    .rotate()
    .resize(1600, 1600, { fit: 'inside', withoutEnlargement: true })
    .jpeg({ quality: 85 })
    .toBuffer();

  // Save file to disk
  fs.writeFileSync(filepath, normalizedBuffer);

  // A small resized copy alongside the original — see schema.prisma's Photo.thumbnailUrl
  // comment for why this exists. Same stretch/crop-to-fill sizing regardless of the source
  // photo's own aspect ratio, since every place this gets shown small is itself a fixed square
  // box (a 56x56 list row, a 96x96 admin queue cell). Built from the already-normalized buffer
  // above, not the raw upload, so it inherits the same correct orientation for free.
  const thumbFilename = `${id}_thumb.jpg`;
  const thumbBuffer = await sharp(normalizedBuffer).resize(300, 300, { fit: 'cover' }).jpeg({ quality: 80 }).toBuffer();
  fs.writeFileSync(path.join(userDir, thumbFilename), thumbBuffer);

  // Return relative paths (used as identifiers)
  const kind = isVerification ? 'verification' : 'photos';
  const relativePath = `${kind}/${userId}/${filename}`;
  const thumbRelativePath = `${kind}/${userId}/${thumbFilename}`;
  console.log(`📸 Photo saved: ${relativePath}`);

  return { url: relativePath, thumbnailUrl: thumbRelativePath };
}

/// Chat images (see routes/match.ts's POST /:matchId/messages/photo), kept in their own
/// `chat/{matchId}/` tree rather than reusing `uploadPhoto()`'s `photos/{userId}/` — different
/// lifecycle (tied to a match, not a profile) and, per product decision, these are **not** run
/// through moderateImage() at all: profile photos are shown to strangers browsing Discovery,
/// chat images are only ever seen by someone you've already mutually matched and exchanged
/// several messages with (see IMAGE_MESSAGE_UNLOCK_THRESHOLD), which is a meaningfully different
/// trust/exposure level. Revisit if that assumption stops holding.
export async function uploadChatImage(buffer: Buffer, matchId: string): Promise<string> {
  const matchDir = path.join(UPLOADS_DIR, 'chat', matchId);
  if (!fs.existsSync(matchDir)) {
    fs.mkdirSync(matchDir, { recursive: true });
  }

  const filename = `${crypto.randomUUID()}.jpg`;
  fs.writeFileSync(path.join(matchDir, filename), buffer);

  const relativePath = `chat/${matchId}/${filename}`;
  console.log(`📸 Chat image saved: ${relativePath}`);
  return relativePath;
}

export async function getPresignedUrl(key: string): Promise<string> {
  // In local mode, return a local file URL
  // The actual file will be served by the /uploads endpoint
  return `/uploads/${key}`;
}

/// Reads a previously-uploaded photo back off disk — used by the admin rescan tool to re-run
/// moderateImage() against photos that were approved before a moderation change (model swap,
/// threshold tuning) so already-live content gets re-checked, not just new uploads.
export function readPhoto(key: string): Buffer {
  return fs.readFileSync(path.join(UPLOADS_DIR, key));
}

export async function deletePhoto(key: string): Promise<void> {
  const filepath = path.join(UPLOADS_DIR, key);

  if (fs.existsSync(filepath)) {
    fs.unlinkSync(filepath);
    console.log(`🗑️  Photo deleted: ${key}`);
  }
}

/// Removes every file this user ever uploaded (profile photos + verification selfie) from disk.
/// `DELETE /account` only removed the DB rows via Prisma's cascade relations — the files
/// themselves were never cleaned up, so they stayed fetchable forever at their old
/// `/uploads/...` URL (no ownership check on that static route) even after the account claiming
/// to delete them was long gone. Safe to call even if a user never uploaded anything.
export function deleteAllUserPhotos(userId: string): void {
  for (const kind of ['photos', 'verification']) {
    const userDir = path.join(UPLOADS_DIR, kind, userId);
    if (fs.existsSync(userDir)) {
      fs.rmSync(userDir, { recursive: true, force: true });
      console.log(`🗑️  Removed ${kind} directory for user ${userId}`);
    }
  }
}

export type ModerationDecision = 'approved' | 'pending' | 'rejected';

// NSFWJS running on plain @tensorflow/tfjs — no AWS, no API keys, no per-image cost,
// classification happens on this machine's own CPU. The model is bundled inside the nsfwjs
// package itself (not fetched from anywhere), so this is fully offline-capable.
//
// Using the InceptionV3 model, not the default MobileNetV2 — MobileNetV2 was tested against a
// real photo that should have been flagged and scored Porn+Hentai at ~5% combined; InceptionV3
// scored the identical photo at ~17% combined, a 3x stronger signal on the same input. Slower
// per-classification (bigger network, 299x299 input vs MobileNetV2's smaller input), but the
// whole point of this system is catching things, so accuracy wins over speed here.
let modelPromise: ReturnType<typeof nsfwjs.load> | null = null;

export function preloadModerationModel(): ReturnType<typeof nsfwjs.load> {
  if (!modelPromise) {
    modelPromise = nsfwjs.load('InceptionV3');
  }
  return modelPromise;
}

/// Three-tier policy based on the model's Porn/Hentai ("explicit") and Sexy ("suggestive")
/// probabilities. Deliberately NOT counting "Drawing" against anyone — that class means
/// "this looks like an illustration/cartoon", not "this is explicit" (that's what Hentai is
/// for), so a stylized/drawn avatar shouldn't be penalized just for being art.
///   - high-confidence explicit -> rejected outright, no human ever sees it
///   - borderline explicit, or high-confidence suggestive -> pending, queued for a human via
///     the admin site's Photos tab (backend/src/routes/moderation.ts)
///   - otherwise -> approved immediately
/// Thresholds are tunable via env vars. History so far:
///   - Pass 1: pending=0.12 — flagged nearly every real upload, review queue useless.
///   - Pass 2: pending=0.35 (this file's previous version) — overcorrected. Two confirmed-clean
///     real photos scored Porn+Hentai at ~0.1-0.2%, but a confirmed-NSFW photo (rear nudity)
///     scored ~25% and still sailed through as approved, since 0.35 was well above it.
///   - Pass 3: pending=0.15 — comfortably above real clean photos (~0.1-0.2%), comfortably
///     below both confirmed-bad examples known at the time (~17-25%).
///   - Pass 4: a real explicit photo (user-reported) scored Neutral 65% / Sexy 14% /
///     Drawing 11% / Porn 7% (Hentai the remaining ~3%) — Porn+Hentai ≈ 0.10, *below* pass 3's
///     0.15 threshold, so it sailed through approved. The model just isn't confident on every
///     explicit photo; some score high Neutral despite being real nudity. Dropped pending to
///     0.05 — still ~25x above the confirmed-clean baseline (~0.001-0.002), and comfortably
///     below this new confirmed-bad example (~0.10).
///   - Pass 5 (current): pending=0.05 turned out to be so aggressive that ordinary stylized art
///     (avatars, fan art, non-explicit illustration) routinely tripped it too — Hentai's training
///     data is anime/illustration-style art in general, not just explicit anime, so it fires on
///     plenty of innocent drawings well above 0.05. That's real reported friction (legitimate art
///     landing in the review queue nearly every time), not a hypothetical. Since a genuinely
///     explicit illustration scores high on *both* Drawing and Hentai/Porn simultaneously (that's
///     what hentai *is*), while innocent stylized art scores high on Drawing but low on
///     Hentai/Porn, the fix is a separate, much higher pending bar that only applies once
///     `looksLikeDrawing` is true — real photos (the pass-4 case this 0.05 floor exists for)
///     are completely unaffected by this since they don't hit `looksLikeDrawing` in the first
///     place.
///   - Pass 6 (current): two more real, conflicting data points arrived close together. A
///     completely SFW drawing scored Hentai 89% alone (no corresponding Drawing-class score
///     high enough to trip the pass-5 `looksLikeDrawing` leeway), so it was being treated as
///     if it were a real explicit photo, right up to outright auto-rejection. Separately, a
///     perfectly ordinary clothed photo (a skirt) scored Porn 20% / Sexy 70% / Neutral 5% — and
///     20% alone was already above pass 4/5's pendingThreshold (0.05), so it landed in the
///     review queue for no real reason.
///     These two data points directly conflict with pass 4's own bad example (Porn+Hentai
///     ≈ 0.10): a threshold that low-enough to catch 0.10 will always also catch the skirt
///     photo's 0.20, since 0.10 < 0.20. The combined-score signal alone can't separate them at
///     this granularity — something has to give, and per explicit product direction the
///     priority is fewer false positives on ordinary/suggestive photos, accepting that a
///     repeat of the pass-4 case might not trip pendingThreshold on its own anymore (Sexy 14%
///     wouldn't reach the pass-6 Sexy bar either). Raised pendingThreshold 0.05 -> 0.3 — the
///     skirt photo's own numbers (Porn 20 / Sexy 70 / Neutral 5) leave at most 5 points split
///     between Hentai and Drawing, so its worst-case Porn+Hentai is ~0.25; 0.3 clears that with
///     real margin rather than sitting right on the boundary.
///     Separately, `looksLikeDrawing` now also triggers on a high Hentai score by itself, not
///     just the Drawing class — Hentai's own definition (explicit *illustrated* content) already
///     implies "this is art," so treating it as its own independent drawing-leeway signal covers
///     exactly the failure case above: whatever score Hentai gets, an actually-explicit
///     illustration still lands in pending (a human decides), it just can never again be
///     auto-deleted with no one looking at it first.
/// Still only a handful of confirmed real data points — treat this as a working hypothesis that
/// improves as the admin Photos queue collects more, not a solved problem.
/// Sexy raised from 0.5 to 0.8 (product decision: suggestive-but-not-explicit content, swimwear,
/// lingerie, workout clothes, is fine on its own and shouldn't cost someone a review-queue delay)
/// — it already fired on plenty of plainly benign photos more readily than Porn/Hentai did, and
/// no confirmed bad example so far has needed it to catch anything Porn+Hentai didn't already.
/// Kept as a high bar rather than removed outright, so something scoring overwhelmingly Sexy
/// still gets a human look.
export async function moderateImage(imageBytes: Buffer): Promise<{
  status: ModerationDecision;
  labels: string[];
}> {
  const model = await preloadModerationModel();

  // nsfwjs's own classify() resizes whatever tensor shape it's given down to a fixed 224x224
  // (see its core.js: `tf.image.resizeBilinear(normalized, [size, size])`, stretching rather than
  // cropping) before running the model — so building a tensor from the image at its *original*
  // resolution was pure waste, held in memory just long enough to immediately get thrown away.
  // For a real phone photo (e.g. 3024x4032) that's tens of megabytes of raw pixels and, worse, a
  // same-shape int32 tensor 4x that size again, on a droplet with under 2GB of RAM total — a
  // large enough upload could balloon this single classification past what the box had free and
  // get the whole worker process killed mid-job, which is exactly what was happening to real
  // stuck-in-pending photos. Resizing to the model's own 224x224 here first, with the same
  // stretch-not-crop semantics nsfwjs's internal resize already uses, means its `shape[0] !==
  // size` check finds an exact match and skips its own resize entirely — identical
  // classification result, at a small fraction of the memory.
  // .rotate() with no args auto-orients from EXIF before resizing — a defensive no-op for
  // anything uploaded after uploadPhoto() started normalizing orientation itself, but real
  // protection for photos already on disk from before that fix, which could otherwise still
  // get classified sideways.
  const { data, info } = await sharp(imageBytes)
    .rotate()
    .resize(224, 224, { fit: 'fill' })
    .removeAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });

  const tensor = tf.tensor3d(new Uint8Array(data), [info.height, info.width, 3], 'int32');
  let predictions: nsfwjs.PredictionType[];
  try {
    predictions = await model.classify(tensor);
  } finally {
    tensor.dispose();
  }

  const scoreFor = (className: string) =>
    predictions.find((p) => p.className === className)?.probability ?? 0;

  const explicitScore = scoreFor('Porn') + scoreFor('Hentai');
  const sexyScore = scoreFor('Sexy');
  const drawingScore = scoreFor('Drawing');

  const rejectThreshold = parseFloat(process.env.MODERATION_REJECT_SCORE || '0.75');
  const pendingThreshold = parseFloat(process.env.MODERATION_PENDING_SCORE || '0.3');
  const sexyPendingThreshold = parseFloat(process.env.MODERATION_SEXY_PENDING_SCORE || '0.8');
  const drawingLeewayThreshold = parseFloat(process.env.MODERATION_DRAWING_LEEWAY_SCORE || '0.15');
  // Only applies once looksLikeDrawing is true (see below) — real photos still use the much
  // more aggressive pendingThreshold above unchanged.
  const drawingPendingThreshold = parseFloat(process.env.MODERATION_DRAWING_PENDING_SCORE || '0.35');

  const labels = predictions
    .filter((p) => p.probability >= 0.05)
    .map((p) => `${p.className} (${Math.round(p.probability * 100)}%)`);

  // Hentai's training data is anime/illustration-style art, so it fires on plenty of innocent
  // stylized art and cartoon avatars too — not just genuinely explicit anime. Auto-rejecting on
  // that signal alone means real art gets permanently deleted with no human ever looking at it.
  //
  // First attempt at this used `drawingScore > explicitScore` ("Drawing is the dominant class"),
  // but all 5 classes sum to ~1, so once explicitScore crosses the 0.75 reject threshold,
  // drawingScore is mathematically capped at ≤0.25 — that comparison could never be true at the
  // exact point a reject would fire, making it dead code. Using an absolute floor instead: any
  // meaningful Drawing signal (the model itself thinks there's a real chance this is illustrated,
  // not photographed) caps the outcome at "pending" rather than "rejected" — still queued for
  // review if it trips a threshold, a human just makes the final call instead of an instant
  // auto-delete. A real photo of an actual person should score Drawing near zero regardless, so
  // this shouldn't weaken protection against real explicit photos.
  //
  // Also triggered by a high Hentai score on its own (see this function's doc comment, Pass 6):
  // a real, confirmed-SFW drawing scored Hentai 89% with the Drawing class itself not crossing
  // the leeway floor, so relying on the Drawing class alone missed it entirely. Hentai's own
  // definition (explicit *illustrated* content) already means "this is art" regardless of what
  // the separate Drawing class happened to score — a real photo of an actual person should score
  // Hentai near zero same as Drawing, so this doesn't weaken protection against real explicit
  // photos either.
  const looksLikeDrawing =
    drawingScore >= drawingLeewayThreshold || scoreFor('Hentai') >= drawingLeewayThreshold;

  if (explicitScore >= rejectThreshold && !looksLikeDrawing) {
    return { status: 'rejected', labels };
  }

  // A drawing needs a much stronger explicit signal than a photo does before it's worth a human's
  // time — see this function's doc comment (Pass 5) for why pendingThreshold alone (0.05) caught
  // ordinary stylized art far more often than it caught anything actually explicit.
  const effectivePendingThreshold = looksLikeDrawing
    ? Math.max(pendingThreshold, drawingPendingThreshold)
    : pendingThreshold;

  if (explicitScore >= effectivePendingThreshold || sexyScore >= sexyPendingThreshold) {
    return { status: 'pending', labels };
  }
  return { status: 'approved', labels };
}
