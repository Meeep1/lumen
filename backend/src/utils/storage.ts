// LOCAL DEVELOPMENT MODE
// Photos are stored on disk instead of S3
// Photo moderation runs for real (see moderateImage below) via a local NSFW model — no AWS

import crypto from 'crypto';
import fs from 'fs';
import path from 'path';
import * as tf from '@tensorflow/tfjs';
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
): Promise<string> {
  // Create user-specific directory
  const userDir = path.join(UPLOADS_DIR, isVerification ? 'verification' : 'photos', userId);
  if (!fs.existsSync(userDir)) {
    fs.mkdirSync(userDir, { recursive: true });
  }

  // Generate unique filename
  const filename = `${crypto.randomUUID()}.jpg`;
  const filepath = path.join(userDir, filename);
  
  // Save file to disk
  fs.writeFileSync(filepath, buffer);
  
  // Return relative path (used as identifier)
  const relativePath = `${isVerification ? 'verification' : 'photos'}/${userId}/${filename}`;
  console.log(`📸 Photo saved: ${relativePath}`);
  
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
/// probabilities:
///   - high-confidence explicit -> rejected outright, no human ever sees it
///   - borderline explicit, or high-confidence suggestive -> pending, queued for a human via
///     the admin site's Photos tab (backend/src/routes/moderation.ts)
///   - otherwise -> approved immediately
/// Thresholds are tunable via env vars. History so far:
///   - Pass 1: pending=0.12 — flagged nearly every real upload, review queue useless.
///   - Pass 2: pending=0.35 (this file's previous version) — overcorrected. Two confirmed-clean
///     real photos scored Porn+Hentai at ~0.1-0.2%, but a confirmed-NSFW photo (rear nudity)
///     scored ~25% and still sailed through as approved, since 0.35 was well above it.
///   - Pass 3 (current): the gap between confirmed-clean (~0.1-0.2%) and confirmed-bad
///     (~17-25%) turned out to be much wider than pass 2 assumed, so pending dropped to 0.15 —
///     comfortably above real clean photos, comfortably below both confirmed-bad examples.
/// Still only ~4 confirmed real data points total (2 clean, 2 bad) — treat this as a working
/// hypothesis that improves as the admin Photos queue collects more, not a solved problem.
/// Sexy stayed conservative (0.5) since it tends to fire on plainly benign photos (swimwear,
/// workout clothes) more readily than Porn/Hentai do, and no confirmed bad example so far has
/// needed it to catch anything Porn+Hentai didn't already.
export async function moderateImage(imageBytes: Buffer): Promise<{
  status: ModerationDecision;
  labels: string[];
}> {
  const model = await preloadModerationModel();

  const { data, info } = await sharp(imageBytes)
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

  const rejectThreshold = parseFloat(process.env.MODERATION_REJECT_SCORE || '0.75');
  const pendingThreshold = parseFloat(process.env.MODERATION_PENDING_SCORE || '0.15');
  const sexyPendingThreshold = parseFloat(process.env.MODERATION_SEXY_PENDING_SCORE || '0.5');

  const labels = predictions
    .filter((p) => p.probability >= 0.05)
    .map((p) => `${p.className} (${Math.round(p.probability * 100)}%)`);

  if (explicitScore >= rejectThreshold) {
    return { status: 'rejected', labels };
  }
  if (explicitScore >= pendingThreshold || sexyScore >= sexyPendingThreshold) {
    return { status: 'pending', labels };
  }
  return { status: 'approved', labels };
}
