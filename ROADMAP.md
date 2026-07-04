# Lumen — Release Roadmap

Status snapshot as of 2026-07-02, updated 2026-07-03. This roadmap is grounded in the actual state of the codebase (not the spec's aspirations) — every item below reflects something confirmed by reading `app_spec.md`, the backend routes/schema, and the iOS views. Where the spec claims a feature exists and it doesn't, that's called out explicitly.

**Phase 1 progress: 6/8 done** — 1.1-1.6 are all complete (see notes inline below). 1.7 (App Store compliance pass) and 1.8 (crash reporting/observability) are still open.

Priorities: **P0** = release blocker (cannot ship without it), **P1** = should ship in v1.0 but app is technically usable without it, **P2** = quality-of-life, do soon after launch, **P3** = future/differentiation.

---

## 0. Current State — the honest picture

What actually works end-to-end today: signup/login/OTP, onboarding, profile editing, photo upload (unmoderated), swipe/discovery/matching, Likes You, REST-based messaging, blocking, reporting (creation side), account deletion, settings toggles.

Still open (see Phase 1 for what changed 2026-07-03):
- **Photo moderation is a no-op.** `moderateImage()` in `backend/src/utils/storage.ts` hardcodes `{ approved: true }`; real Rekognition integration is dead commented-out code.
- **Suspension isn't enforced after login.** A suspended user's existing JWT still passes every authenticated route except the login check itself.
- **Push notifications don't exist.** No APNs, no device-token storage, no permission prompts, no server-side trigger logic.
- **Sign in with Apple is missing**, despite being required by App Store guidelines whenever another third-party login exists and being called out in the spec.
- **Zero automated tests** anywhere in either codebase.

Resolved this session (2026-07-03):
- Real-time chat now works (WebSocket-based, not Socket.IO — see 1.1).
- Admin moderation endpoints are now authenticated (see 1.2).
- Verification has a full submit/review flow, not just schema fields (pulled forward from Phase 2.2 — see below).
- An admin web dashboard exists (see 1.6).

Everything below is organized to close the remaining gaps in a sane order and then build outward.

---

## Phase 1 — Release Blockers (P0)

Nothing ships to TestFlight/App Store until this phase is done. Ordered roughly by dependency.

### 1.1 Real-time chat (SocketManager rebuild) — ✅ DONE (2026-07-03)
- Built differently than originally scoped: `socket.io-client-swift` couldn't be resolved via SPM in this dev environment (`xcodebuild -resolvePackageDependencies` never completed a resolution, likely needs an interactive Xcode session unavailable here). Swapped the whole real-time layer to a plain WebSocket instead — backend now uses `@fastify/websocket` (`backend/src/socket/handlers.ts` rewritten with a per-user socket registry replacing Socket.IO rooms), and `SocketManager.swift` uses Foundation's native `URLSessionWebSocketTask` — zero external dependencies.
- `connect()`/`disconnect()` wired to JWT-authenticated lifecycle (bearer token via request header), reconnect-with-backoff on drop, app-level keepalive ping every 30s (doubles as Redis online-status refresh).
- `sendMessage`/`typing`/`mark_read` and their listeners (`new_message`/`user_typing`/`messages_read`) all implemented and verified live with a two-client test — message delivery, typing indicator, and read receipts all round-trip correctly.
- Not yet done: explicit reconciliation of the REST send path (`match.ts`) vs. socket path beyond client-side dedup-by-id — works today, but worth a deliberate audit later.

### 1.2 Admin authorization — ✅ DONE (2026-07-03)
- `requireAdmin` middleware added (`backend/src/middleware/auth.ts`), checks `User.isAdmin` after JWT verification, applied to both `GET /reports/admin` and `POST /reports/admin/:reportId/action`.
- `npm run make-admin -- <email>` (and `--revoke`) added as the way to grant/revoke admin access.
- Verified: non-admin gets 403, admin gets 200.

### 1.3 Suspension enforcement — ✅ DONE (2026-07-04)
- `authenticate` middleware now fetches `isSuspended`/`suspendedUntil` on every request (not just login) and rejects with `403 {error, code: "ACCOUNT_SUSPENDED"}` if still active; auto-clears the suspension if `suspendedUntil` has already passed. Also fixed a related pre-existing bug found while testing this: the login route's own suspension check didn't account for expiry either, so anyone whose temporary suspension had already lapsed was permanently locked out (login was the only way to get a token, and nothing ever cleared `isSuspended` for them) — login now auto-clears expired suspensions the same way.
- `requireAdmin` now reuses the `isAdmin` flag `authenticate` already fetched (stashed on `request.userIsAdmin`) instead of a second DB query.
- iOS: `APIError.accountSuspended`, `ErrorResponse.code`, and a `.accountSuspended` `NotificationCenter` event so `APIService` (which has no reference to `AuthenticationManager`) can still trigger a forced logout + on-brand alert on `AuthenticationView` without a circular dependency.
- Verified via curl: active suspension blocks both login and mid-session requests with an already-issued token; expired suspension auto-clears on either path; admin gating still works post-refactor.
- **Not covered:** the two multipart upload methods (`uploadPhoto`, `submitVerificationPhoto`) don't go through the shared `request()` method, so they won't trigger the client-side forced-logout flow specifically (they'll still get the 403 from the server, just surfaced as a generic error rather than the dedicated suspension alert).

### 1.4 Photo moderation — ✅ DONE (2026-07-04), revised same day
- First pass wired up AWS Rekognition gated behind `NODE_ENV=production` — but that meant local dev kept auto-approving *everything*, including actually-NSFW test uploads, which is how this got caught (user uploaded NSFW content locally and it sailed through). Replaced Rekognition entirely with **NSFWJS** (MobileNetV2 trained for NSFW classification) running on plain `@tensorflow/tfjs` + `sharp` for image decoding — no AWS, no API keys, no per-image cost, classification runs on the server's own CPU, and it's active in dev and prod alike now (no environment gate at all). `@tensorflow/tfjs-node` (the native-bindings version) failed to compile in this environment (missing Xcode headers), so this uses the pure-JS tfjs backend instead — slower per-classification (~150-250ms) but zero native build step.
- Same three-tier policy as before, now driven by NSFWJS's Porn/Hentai/Sexy probability scores instead of Rekognition labels: high-confidence explicit → `rejected` outright, borderline explicit or high-confidence suggestive → `pending` (queued for a human via the admin site's Photos tab), otherwise → `approved`. Thresholds tunable via `MODERATION_REJECT_SCORE`/`MODERATION_PENDING_SCORE`/`MODERATION_SEXY_PENDING_SCORE` env vars (defaults 0.85/0.4/0.7).
- Model loads once at server boot (~1-2s, added to the existing Prisma/Redis warm-up in `server.ts`) rather than on the first upload. One-time network fetch of the model weights (~5MB, from NSFWJS's public GitHub-hosted default) on first load each process start — no per-request network calls after that.
- `backend/src/routes/moderation.ts` (`GET /moderation/photos?status=`, `POST /moderation/photos/:photoId/action`) and admin site's "Photos" tab unchanged from the first pass — they just read/write `Photo.moderationStatus`, agnostic to what set it.
- Verified: real classification against a real photo (correct probabilities returned), threshold branching logic (6 cases covering all three outcomes), local-dev upload actually runs moderation now (no more blanket auto-approve), and the admin approve/reject queue still works end-to-end.
- **Update (2026-07-04, later same day):** the "not verified against real NSFW" gap above got closed for real — user reported an actual NSFW upload sailed through, which is exactly the scenario that couldn't be tested synthetically. Root-caused for real this time:
  - NSFWJS ships two bundled models. The default (`MobileNetV2`) scored the real flagged photo at only ~5% combined Porn+Hentai — nowhere near the 0.4 pending threshold. Switched to the bundled `InceptionV3` model, which scored the *identical* photo at ~17% — a 3x stronger signal on the same input, confirmed via direct side-by-side testing (not just theory). Verified no NaN/preprocessing bugs first (pixel data, tensor construction, and normalization all checked correct) before concluding it was a model-choice problem, not a pipeline bug.
  - Recalibrated thresholds down to match the score ranges these models actually produce (clean photos: ~3-5% combined explicit; the one confirmed-bad photo: ~17%): reject 0.85→0.5, pending 0.4→0.12, sexy-pending 0.7→0.15. Explicitly flagged in the code as a first-pass recalibration against a sample size of one, not a settled result.
  - Re-uploaded the exact same real photo through the actual endpoint post-fix: now correctly lands on `pending` instead of `approved`.
  - Added `POST /moderation/rescan` (admin site "Rescan Approved Photos" button) so photos approved *before* this fix — the "it's still there" half of the complaint — get re-checked, not just new uploads. First version of this **froze the entire server for other users** (single-threaded Node, each classification is 5-12s of blocking synchronous CPU work, and it was churning through 200+ mostly-synthetic seed-test photos); had to kill the stuck process mid-run. Fixed by excluding seed/test accounts from rescan (they're synthetic images we control, not real content) and adding an event-loop yield between each photo. Re-run against the real account: found and flagged all 4 previously-"approved" photos (1 auto-rejected at 98% Hentai, 3 sent to pending review) — confirms the original bug was real and this catches it.
  - Also found and fixed while investigating: the admin site's "Failed to load photo queue" was a red herring — `@fastify/rate-limit`'s 100 req/min (shared per source IP) was getting exhausted by normal admin-site + testing traffic, not a real endpoint bug. Bumped to 500/min for local dev.
  - **Still open:** every single photo upload now costs 5-12s of blocking server time (InceptionV3 is a real, heavy network, and pure-`@tensorflow/tfjs` has no GPU/native acceleration in this environment). Acceptable for a single admin doing manual testing; would need a job queue or a faster backend (the tfjs-node native build that failed to compile here, or a real inference server) before this could handle concurrent real users without one photo upload stalling everyone else.
  - **Update (2026-07-04, later still):** two more rounds of real-world threshold tuning happened after the above. (1) `GET /profile/me` was found to filter to `moderationStatus: 'approved'` same as viewing someone else's profile — so any of *your own* pending photos just vanished with no explanation ("seems to not be added"). Fixed: your own profile now shows every photo regardless of status, with the status included so the app can badge it. (2) The pending threshold (0.12) turned out to flag nearly every real upload, so it got raised to 0.35 — which then overcorrected the other way: a real NSFW photo (rear nudity, scored ~25% combined Porn+Hentai) sailed through as approved because 0.35 was well above it, while two confirmed-clean real photos scored only ~0.1-0.2%. The clean/bad gap was much wider than assumed, so pending dropped to **0.15** — verified against all 4 confirmed real examples now on hand (2 clean, 2 bad) and it correctly separates all of them. Also added photo management UI (`ManagePhotosView.swift`, `PhotoCropView.swift`) — reorder, delete, and a crop step before upload — closing out Phase 2.3 early, since it was directly requested alongside these bug reports.

### 1.5 Sign in with Apple — ✅ DONE (2026-07-04)
- Scoped deliberately: Apple only replaces the *password* step, not the rest of this app's signup requirements (phone/OTP, age, gender identity, fem attestation all still apply either way) — the alternative (letting Apple's identity alone create a fully-formed account) would have meant making `dateOfBirth`/`genderIdentity`/`phone` nullable throughout the schema, which ripples into nearly every route and the iOS `User` model. Not worth that blast radius for what this app actually needs Apple Sign In for.
- Schema: `passwordHash` and (new) `appleUserId` are both nullable/unique. `POST /auth/apple` (login/link path) and `POST /auth/signup` (new field `appleIdentityToken`) both **re-verify the Apple identity token server-side** via `apple-signin-auth` — deliberately not trusting a client-supplied Apple user ID directly, since that would let anyone claim any identity string with no proof of ownership.
- Flow: tap "Sign in with Apple" → if an account already exists for that Apple ID (or a matching email, auto-linked) → straight to login. If not → `AppleSignInOutcome.needsSignup` routes to the same signup form, pre-filled with whatever email Apple provided, password fields hidden.
- iOS: `SignInWithAppleButton` used as-is, no custom styling — Apple's Human Interface Guidelines require their standard button for this specific control, unlike the custom-UI work done elsewhere in the app.
- Verified: invalid/malformed identity tokens correctly rejected (401) on both the login and signup paths; existing email/password login confirmed unaffected (regression check).
- **Not verified: the actual Apple-signed-token path end-to-end.** No way to generate a real Apple identity token without a real device signed into a real Apple ID and this app's bundle ID actually configured for Sign In with Apple. Two external dependencies remain, both outside this repo: (1) the **Apple Developer Portal capability** for "Sign In with Apple" must be enabled for `com.camdenheil.lumen` — that requires the Apple Developer account this app is registered under, which isn't something I have access to; (2) real on-device testing, once that's enabled.

### 1.6 Minimal admin moderation surface — ✅ DONE (2026-07-03), exceeds "minimum viable"
- Built as `backend/public/admin/index.html`, served at `/admin/` by the backend itself (admin-JWT-gated, same login as the app). Not bare-bones — has a real (if simple) design system, a Reports tab (filter by status, take action: warn/temp-suspend/permanent-suspend), and a Verification tab (see 2.2, pulled forward and built this session too) showing selfie vs. profile photos side-by-side with approve/reject.
- Tested end-to-end via curl: filed a report, suspended a test account through the site, confirmed the DB updated, reverted it.

### 1.7 App Store compliance pass
- Privacy nutrition label accuracy (location, photos, contact info collected — matches what's actually collected).
- Age gate (18+) — already implemented client + server side; verify server rejects DOB edge cases (exactly 18 today, leap-year DOBs).
- Terms of Service / Privacy Policy links in `SettingsView.swift` — confirm they point to real, current documents, not placeholders.
- Account deletion — confirm it's discoverable within the app per guideline 5.1.1(v) (it exists in `SettingsView.swift`; just needs a final UX check that it's not buried).
- Content moderation + user-blocking/reporting — required for UGC apps under 1.2; largely covered by 1.2/1.3/1.4/1.6 above, but do an explicit guideline-by-guideline checklist pass before submission.
- **Effort: Medium**, mostly review/checklist rather than new code.

### 1.8 Crash reporting & basic observability
- No crash reporting SDK currently. Add one (e.g. Sentry, or Apple's own MetricKit + Xcode Organizer at minimum) before real users are on the app — flying blind on crashes post-launch is not viable.
- Backend: basic structured logging + error alerting beyond the current console/log-file approach (`/tmp/lumen-backend.log` is a local dev convenience, not production infra) — a hosted log aggregator or at minimum a process manager (pm2/systemd) with restart-on-crash and log rotation.
- **Effort: Medium.**

---

## Phase 2 — Should Ship With v1.0 (P1)

Not launch-blocking in the sense that the app functions without them, but launching without them creates a materially worse first-week experience or foreseeable support burden.

### 2.1 Push notifications — partially done (2026-07-04): photo moderation outcomes only
- **What exists now:** when a photo gets approved/rejected (admin action or rescan), the backend sends a `photo_reviewed` event over the existing WebSocket connection (see `sendToUser` calls in `moderation.ts`), and the iOS client schedules a **local** notification (`UNUserNotificationCenter`) on receipt, plus refreshes `currentUser` so the UI updates without a manual pull-to-refresh.
- **This is not real push.** It only fires while the app's socket is actually connected (open, or very recently backgrounded) — there's no APNs integration, no device-token storage, no delivery when the app is fully closed/backgrounded for a while. Real push still needs everything below.
- Add `pushToken`/`platform` fields to `User` (Prisma migration).
- iOS: request notification permission at an appropriate point in onboarding (not on first launch — request contextually, e.g. after first match), register for remote notifications, send token to a new `POST /profile/push-token` endpoint.
- Backend: integrate APNs (via `node-apn` or Apple's HTTP/2 APNs API directly), replace the `console.log` TODO at `socket/handlers.ts:125` with a real send when the recipient is offline.
- Trigger points: new match, new message (only if recipient not actively in that chat / app backgrounded), new like (respecting the spec's note to consider batching rather than instant-per-like, which could get spammy fast for popular profiles).
- Add notification preference storage server-side (currently `NotificationPreferencesView.swift` in Settings appears to be local-only — preferences should persist and actually gate whether a push fires).
- **Effort: Large**, though the photo-moderation slice above is done and the same WebSocket-event → local-notification pattern could extend to matches/messages relatively cheaply if full APNs keeps getting deferred.

### 2.2 Verification flow (end to end) — ✅ DONE (2026-07-03), pulled forward from Phase 2
- Backend: `backend/src/routes/verification.ts` — `POST /verification/submit` (selfie upload, sets `verificationStatus: pending`), `GET /verification/status` (own status), admin `GET /verification/admin` + `POST /verification/admin/:userId/action` (approve/reject, admin-gated, flips `isVerified`, sets `verificationReviewedById`/`verificationReviewedAt`).
- iOS: `VerificationView.swift`, reachable from Settings — status badge (none/pending/approved/rejected), photo-library selfie picker (no live-capture/liveness check — honest MVP scope, manual review only), submit/resubmit.
- Admin site: Verification tab shows the selfie next to existing profile photos side-by-side for comparison, with Approve/Reject buttons.
- Tested end-to-end: submitted a selfie, saw it in the admin queue, approved it, confirmed `isVerified` flipped in the DB; rejected another and confirmed it didn't.
- **Not done:** no automated face-match/Rekognition `CompareFaces` step — every request needs a human reviewer today. Revisit if review volume becomes a bottleneck (ties into Phase 1.4's Rekognition work, same AWS service).

### 2.3 Profile photo management UI — ✅ DONE (2026-07-04)
- `ManagePhotosView.swift` (reorder via drag, swipe-to-delete) + `PhotoCropView.swift` (pinch/pan crop step before every new upload) — reachable from Edit Profile and from the profile tab's "Manage Photos" button.
- Guards against a real edge case found via user testing: dropping to zero photos made `User.needsOnboarding` true again (it checks `photos.isEmpty`), bouncing the user straight back into the onboarding flow when they were just tidying up existing photos. Fixed by requiring at least one photo at all times rather than changing the onboarding-completion model.
- Also fixed a staleness bug found via testing: the view was reading photos from `authManager.currentUser`'s cache instead of fetching fresh, so a photo removed server-side (e.g. an admin rejecting it from the admin site) kept showing up client-side and failed to delete with "Photo not found" in a stuck loop. Now refreshes from the server on every appearance, and a "not found" delete error is treated as success (the photo's gone either way) rather than shown as a scary error.

### 2.4 Automated testing — minimum viable coverage
- Backend: integration tests (Vitest or Jest + supertest-equivalent for Fastify) covering the highest-risk paths first: auth (signup/login/OTP), swipe/match creation, block/report, account deletion cascade. Given zero coverage exists, don't aim for exhaustive — aim for "the paths that would be catastrophic to silently break."
- iOS: at minimum, unit tests around `APIService.swift` decoding/encoding (given the exact class of bug already hit this session — the Zod-array-vs-string mismatch — model/decoding tests would have caught that class of regression automatically) and `AuthenticationManager` state transitions.
- CI: wire whichever test suite exists into a GitHub Actions (or similar) pipeline that runs on every PR, even if coverage starts thin — the value is in having the pipeline exist so coverage can grow.
- **Effort: Large, but can be incremental** — don't block launch on 100% coverage, block it on "the account-deletion and payment-adjacent paths have tests," which is a much smaller slice.

### 2.5 Rate limiting & abuse prevention
- Spec §8 calls for rate limiting; confirm current state (likely not implemented — worth a quick grep/check) and add it for at minimum: OTP send/resend (SMS cost + abuse vector), login attempts (brute force), report creation (spam-reporting as harassment vector), swipe endpoint (bot/scraping prevention).
- `@fastify/rate-limit` is the natural fit given the stack.
- **Effort: Small–Medium.**

### 2.6 Signed/expiring photo URLs
- Spec §8 requires this; confirm current photo-serving approach (local disk fallback per `storage.ts` — check whether URLs are currently just static/guessable paths). Before S3 migration, at minimum ensure local-serving isn't trivially enumerable; after S3 migration (see 3.x), use real signed URLs with short expiry.
- **Effort: Small once on S3, Medium if needs interim local-disk hardening.**

---

## Phase 3 — Infrastructure & Production Readiness (P1/P2, parallel track)

These aren't user-facing features but block a real production launch regardless of app feature-completeness.

- **S3 (or equivalent) for photo storage** — replace local-disk fallback (`storage.ts`) for production; local disk doesn't survive redeploys/scaling and has no CDN.
- **Twilio for real SMS** — replace console-logged OTP for production (already scaffolded, just needs credentials + removing the `NODE_ENV` bypass in prod).
- **Managed Postgres + Redis** — confirm hosting plan (RDS/Supabase/Neon + managed Redis) rather than whatever local setup is used in dev.
- **Environment/secrets management** — audit `.env` handling, ensure no secrets are committed, set up proper secret storage for prod (not just a `.env` file on a server).
- **Backups** — automated Postgres backups with a tested restore procedure before real user data exists.
- **HTTPS/TLS + domain** — spec §8 requirement; need a real domain, cert (Let's Encrypt/managed), and to replace the hardcoded LAN IP (`192.168.68.59`) in `APIService.swift` with the production API host, ideally via a build-configuration-based base URL (Debug → LAN IP or localhost, Release → production domain) rather than a single hardcoded constant.
- **Effort: Large overall, but mostly configuration/ops rather than new code.**

---

## Phase 4 — Fast-Follow / QoL (P2, post-launch v1.1–1.2)

Things that materially improve the experience but are fine to ship 2-6 weeks after v1.0.

- **Typing/online-status polish** — presence tracking already exists in Redis (`socket/handlers.ts`); surface "Active now" / "Active 2h ago" in chat and match list once real sockets (1.1) are live.
- **Read receipts UI polish** — backend supports it; confirm `ChatView.swift` renders it well (double-check vs. the SocketManager stub, since a real client will change what data actually arrives).
- **Message image sending UI** — spec's 3-message unlock threshold is implemented server-side (`IMAGE_MESSAGE_UNLOCK_THRESHOLD`); confirm `ChatView.swift` has a working image picker/send UI gated on that, not just text.
- **Undo last swipe** — common dating-app QoL feature, easy addition once swipe history is queryable; low complexity, meaningfully reduces "oops, wrong direction" frustration.
- **Swipe gesture polish** — the current disambiguation heuristic (`ProfileCardView.swift`, 1.5x directional bias) is a pragmatic approximation; revisit after real usage data/feedback — likely fine, but worth a deliberate test pass on a real device across a range of swipe speeds/angles.
- **Empty states & loading polish** — audit every screen for a real empty/error state (e.g. no candidates left, no matches yet, chat load failure) rather than blank screens or console-only errors (several `catch` blocks currently just `print()` the error with no user-facing fallback — grep `print("` in Swift files for the full list).
- **Onboarding drop-off analytics** — instrument step completion so you can see where users abandon onboarding (mandatory location+photo steps are the biggest likely drop points).
- **Notification preferences that actually persist server-side** — depends on 2.1's push-token/preferences table; make sure toggles in `SettingsView.swift` do something once push exists.
- **Report reason follow-up** — after a report is actioned, consider a lightweight "thanks, we reviewed this" notice to the reporter (increases trust that reports aren't going into a void) — optional but cheap.
- **Effort: mostly Small–Medium items, good sprint filler between bigger phases.**

---

## Phase 5 — New Features (P3, post-launch, differentiation/growth)

Bigger bets, sequence based on user feedback after v1.0/1.1 rather than pre-committing.

- **Targeted-like UI revival, done differently.** The backend/schema already fully support liking a specific photo/prompt with a comment (`Swipe.likedPhotoId`/`likedPromptNumber`/`message`) — it was tried as a discovery-card affordance and pulled this session in favor of plain swiping (the two interaction models fought each other in one place). Worth revisiting as a *separate* interaction, not layered onto the swipe card — e.g. a "comment on their answer" option available specifically from the **Likes You** detail view (`LikeResponseView.swift`) or from within a full profile view, which doesn't compete with the swipe gesture at all.
- **Super Like** — the `Swipe.direction` enum already includes `super_like` and the match logic already treats it as match-triggering server-side, but there's no iOS affordance for it at all. Small lift to surface (a button on the card in addition to swipe), and it's a natural low-cost engagement/monetization lever later.
- **Profile "boosts"** — temporary discovery-priority, natural monetization hook once a Pro tier exists (spec explicitly defers monetization — flag this as the first thing to build if/when that's greenlit).
- **Pro tier / subscriptions** — StoreKit 2 integration, paywall, feature gating (candidates: unlimited likes-you-detail, boosts, super likes, see-who-viewed-you). No code exists for this yet; scope only once there's a monetization decision, since the spec deliberately keeps v1 free.
- **Icebreaker prompts in chat** — AI or curated conversation-starter suggestions for new matches, addresses the classic "matched but never messaged" dating-app problem.
- **Video prompts** — short video responses alongside the two text prompts, differentiator vs. static-photo-only competitors; meaningful iOS media-handling lift (recording, compression, storage costs).
- **Community/events feature** — meetup or community-board feature sometimes seen in niche dating apps to build community beyond 1:1 matching; speculative, gauge user demand first.
- **Referral/invite system** — growth lever once there's a real user base worth growing.
- **Web companion app** — read/reply to matches from a browser; only worth it once mobile retention data justifies the investment.

---

## Suggested Sequencing

```
Now → Launch
  Phase 1 (P0 blockers)         ─────────────────────────────►  gate to App Store submission
  Phase 3 (infra, parallel)     ─────────────────────────────►  gate to production traffic
  Phase 2 (P1, mostly parallel) ───────────────────────►  ship with v1.0 if timeline allows,
                                                             otherwise immediate v1.0.1/1.1

Post-Launch
  Phase 4 (QoL)   ── v1.1 – v1.2, driven by real usage feedback
  Phase 5 (new)   ── v1.3+, driven by retention/engagement data and any monetization decision
```

Realistic ordering within Phase 1: **1.2 (admin auth) and 1.3 (suspension enforcement) first** — they're small, they're live security holes, do them today. **1.1 (real chat) next** — it's the biggest single gap and everything chat-adjacent (2.1 push, 4.x chat polish) depends on it being real. **1.4 (moderation) and 1.7 (compliance)** can run in parallel with 1.1 since they're independent surfaces. **1.5 (Sign in with Apple)** — resolve the open question below before scheduling, could turn out to be unnecessary for v1.

---

## Open Questions (need a decision, not just an estimate)

1. **Is Sign in with Apple actually required for this app** under current App Store guidelines, given the current login methods are email/password + phone OTP (no existing third-party social login)? Worth a direct check against current guideline text before committing the engineering time either way.
2. **Manual vs. automated verification review** — is a Rekognition face-compare auto-approve threshold acceptable, or does every verification need human eyes for launch? Affects 2.2 scope significantly.
3. **Push notification batching** — spec flags this as worth considering but defers the decision; resolve before 2.1, since "instant like notification" vs. "digest" changes the data model (need to decide if un-sent/batched likes need their own queue table).
4. **Monetization timing** — is there a target date/trigger for Phase 5's Pro tier, or is it fully deferred until post-launch metrics justify it? Affects how much to future-proof the schema now vs. later.
5. **Admin dashboard investment level** — is the bare-bones internal page (1.6) acceptable long-term, or does it need to become a real internal tool once report volume grows? Fine to defer this decision until volume data exists.
