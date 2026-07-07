# Lumen — Release Roadmap

Status snapshot as of **2026-07-07**. This is a full revamp of the previous roadmap — the app went from "no admin system, no production deploy" to **live in production at `lumenfem.app`** with a real team-permission admin system, a hardened moderation pipeline, and a fixed real-time chat bug, all in the last two days. This doc is reorganized around where things actually stand now: a short list of true pre-submission blockers, a production-hardening list for what's live but not yet bulletproof, and a much bigger, more concrete new-features section for what comes after launch.

Priorities: **P0** = blocks App Store submission, **P1** = blocks calling production "solid," **P2** = quality-of-life fast-follow, **P3** = growth/differentiation bets.

---

## 0. Current State — the honest picture

**Live in production today:** `https://lumenfem.app` — Fastify API + public site + admin panel behind Caddy/TLS on a DigitalOcean droplet, Postgres + Redis on the same box, a separate `lumen-worker` process for photo moderation, pm2-managed, with a real `DEPLOYMENT.md` runbook covering all of it including admin/test-account bootstrapping.

**What works end-to-end:** signup/login/OTP (email + Sign in with Apple), onboarding, profile editing, photo upload with background moderation, swipe/discovery/matching, Likes You, real-time WebSocket chat (single delivery path now, see today's fixes below), blocking, reporting with full admin review (profile + chat transcript), self-service account deletion (files and all), push notifications via real APNs credentials, crash reporting to Sentry, rate limiting on every abuse-prone route, a backend integration test suite in CI, and a public marketing site with real Terms/Privacy/Community Guidelines pages.

**New since the last roadmap (2026-07-05, today):**
- **Admin system rewritten from scratch.** Admins are no longer just a flag on a dating-app `User` row — there's a dedicated `AdminUser` table, its own login (`/admin-auth/login`), and per-admin **permissions** (`moderation`, `reports`, `verification`, `testTools`) instead of all-or-nothing access. A `isSuperAdmin` flag can manage the rest of the team from a new **Team tab** in the admin panel (invite, edit permissions, deactivate, delete) — no more editing the database by hand to add a moderator. Bootstrapped via `npm run create-admin`.
- **Found and fixed a real architecture bug in Basic Auth + Bearer token stacking.** The admin panel used to require both an HTTP Basic Auth header *and* a Bearer JWT on the same API calls — structurally impossible, since a request only carries one `Authorization` header. Basic Auth now only gates the static site and the login endpoint; everything past login relies on the admin's own token.
- **Fixed a real duplicate-message bug.** `ChatView.swift` was sending every message through *both* the WebSocket and the REST API, and the backend created a separate DB row on each path — every message was actually being persisted twice. Fixed by making message delivery (broadcast + push) a single shared function called from whichever path actually created the message, and the client now sends through REST only.
- **Fixed a real rate-limiting bug.** The global rate limiter (100 req/min/IP) applied to `/uploads/*` static image serving too, with no exclusion — loading a page full of photo thumbnails (admin queue or Discovery) could burn the whole per-minute budget on images alone and then 429 unrelated API calls. Excluded static asset serving from the limiter.
- **Photo moderation is now ~50-200x faster.** Swapped `@tensorflow/tfjs` (pure JS backend) for `@tensorflow/tfjs-node` (compiled native TensorFlow) in the moderation worker. Benchmarked directly: **9.7s → 54ms** per classification, identical predictions, confirmed on both dev (arm64 Mac) and production (linux x64). Real end-to-end uploads now classify in **~100-200ms**, down from 5-12+ seconds. This is very likely the actual root cause behind a class of BullMQ "Missing lock"/"stalled job" errors also found and tuned around today (`lockDuration`/`stalledInterval` in `worker.ts`) — those existed because slow classification blocked the worker's event loop long enough to delay BullMQ's own internal timers.
- **Admin Photos queue UX fix.** A photo with no score shown used to look identical to a mysterious silent flag — actually just meant "uploaded, not yet classified by the worker" (every photo defaults to `pending` the instant its row is created, before classification runs). Now shows an explicit "still being scanned" notice instead of a blank space.
- **iOS debug environment picker.** Debug builds only (doesn't exist in Release/TestFlight/App Store builds at all): 5-tap the login screen's logo to flip between local dev and production without rebuilding — for fast manual testing against either server.
- **Legal pages finalized.** Governing jurisdiction (Ohio) and effective date filled in, "before you publish this" author notes removed, contact emails moved from the `meeep.xyz` dev domain to `@lumenfem.app`.
- **App version set to `0.1`** (was defaulted to `1.0`, inaccurate for current maturity).
- **Direct SSH access to the production server** is now available for faster iteration — no more relaying commands through copy-paste.

**New since the last roadmap (2026-07-07, today):** a mix of real user-reported bugs (dogfooding the live app) and the fixes that followed.
- **Fixed a real photo-moderation memory bug — likely the actual cause of photos getting stuck in `pending`.** `moderateImage()` was building a TensorFlow tensor from an uploaded photo's *original* resolution before classifying it, even though NSFWJS immediately resizes it down to 224x224 internally regardless. A real phone photo (several thousand pixels per side) meant decoding tens of megabytes of raw pixels into a same-shape tensor roughly 4x that size again — on this droplet's 2GB of RAM, occasionally enough to get the whole worker process killed mid-classification. Fixed by resizing to 224x224 with `sharp` *before* building the tensor, using the same stretch-not-crop semantics NSFWJS's own internal resize already used (identical classification behavior, verified on a real 3024x4032 test photo: 54ms and a ~2.6MB memory delta instead of building a multi-hundred-MB tensor). A real stuck photo, reported live, was reprocessed and resolved once this shipped.
- **Chat images:** fixed a sizing bug (`maxWidth`/`maxHeight` with no floor could collapse an image bubble to a barely-visible sliver — same class of bug `ProfileCardView` already had a fix pattern for), and added tap-to-fullscreen viewing (pinch to zoom, drag/tap to dismiss).
- **Location privacy leak, actually fixed twice over.** The onboarding location step was reverse-geocoding to a full street address (`MKAddress.shortAddress`/`.fullAddress`) instead of a city, contradicting the app's own "we only ever show your city" copy — fixed via `MKMapItem.addressRepresentations.cityName`. But location was also only ever *set once*, during onboarding, with no way to refresh it afterward — so an account whose city was saved before that fix had no path to a corrected value short of deleting the account. Added **Settings → Update Location** to close that gap for good.
- **Match celebration screen:** now prompts "Send a Message" directly into the new match's chat (previously just said "say hi from the Matches tab" with no direct path there), got a visual pass (radial glow, pulsing ring, gradient title), and now actually covers the custom bottom tab bar — it previously only ever covered up to where the tab bar's reserved space began, leaving it visible and tappable underneath an otherwise full-screen moment.
- **Verification reworked from a fakeable single photo to camera-only + a pose prompt.** Previously accepted any photo from the library via `PhotosPicker` — "verified" meant nothing more than "uploaded a JPEG." Now: (1) capture is locked to the live camera (`UIImagePickerController` with `sourceType = .camera`, no library access at all), and (2) the app fetches a random pose prompt (peace sign, thumbs up, hand on chin, etc.) moments before opening the camera and requires it to actually appear in the selfie, replacing an earlier "hold up this code" design that didn't match how any other dating app's verification looks or feels. Same anti-replay mechanics as the code it replaced, just expressed as an ordinary gesture. The admin queue surfaces the expected pose so a reviewer can confirm it's actually visible before approving.
- **Fixed onboarding silently skipping the rest of the flow mid-session.** `needsOnboarding` is a live check (has a location + a photo), not a "did this user actually click through the flow" flag. The first photo uploaded during onboarding gets moderated like any other, and once that finishes, a socket event refreshes the profile to keep photo statuses current — but that same refresh re-evaluates `needsOnboarding` too, and the instant it read `false`, the app's root view swapped straight to the main app regardless of which onboarding step the user was actually on. Got much more noticeable once photo moderation started finishing in ~1s instead of much later (see the memory fix above). Fixed with a latch: once onboarding is shown, it stays shown until it's explicitly finished, regardless of that check re-evaluating in the background.
- **Moderation thresholds tuned twice more, against real conflicting reports.** A confirmed-SFW drawing scored Hentai 89% with the model's own Drawing-class score too low to trip the existing drawing-leeway logic, putting it at risk of outright auto-rejection like a real explicit photo — fixed by also treating a high Hentai score on its own as "this is art," since that's Hentai's own definition. Separately, an ordinary clothed photo (Porn 20% / Sexy 70%) was landing in the review queue for no real reason, and suggestive-but-not-explicit content generally was being held to too aggressive a bar — raised the general pending threshold (0.05 → 0.3) and the Sexy-alone review trigger (50% → 80%) per explicit product direction, accepting that a past low-scoring real explicit photo might not trip the combined-score signal alone anymore. Both real reported photos were reprocessed and confirmed correct under the new logic before closing out.
- **Admin panel redesigned** from a flat row of nav buttons into a real sidebar-based dashboard layout (branded header, shadowed cards, responsive down to phone width), and gained a new **Thresholds tab** — a plain-language reference for every moderation cutoff and what each of the model's five classifier scores (Porn, Hentai, Sexy, Drawing, Neutral) actually does in the decision, so a moderator looking at a label like "Porn (34%)" has something to check it against.
- **Em dashes removed** from all user-facing app copy, the marketing site, legal pages, and the admin panel — they read as AI-generated prose; replaced with ordinary punctuation throughout.
- **Debug builds now default to production, not local** — the server is cheap to iterate on directly (SSH access, a two-command deploy), so a fresh Xcode build talks to the real backend out of the box instead of requiring `npm run dev` running locally too.
- **Local dev toolchain moved to Xcode 27** (beta) at the account holder's request — relocated from `~/Downloads` to `/Applications` for a stable home, `xcode-select` repointed at it.

**The recurring Redis `ETIMEDOUT` (Phase 2 called this restart-time-only and not a real issue) turned out to have a real, separate cause after all** — see the 2026-07-07 section below. The worker wasn't just briefly starved during model load; classifying a full-resolution phone photo built a tensor large enough to occasionally exhaust this 2GB droplet's memory outright and kill the process mid-job, which is what actually left photos stuck in `pending` far past the documented ~54ms. Fixed today (resize before classify); Redis's own retry logic had already been masking the symptom well enough that it took a user-reported stuck photo to surface it.

**Decisions made (2026-07-07):** photo storage stays on local disk (accepted at current scale), Postgres/Redis stay self-hosted on the droplet (accepted at current scale), and `lumen.xcodeproj` is now tracked in git (was the last genuinely open item). Nothing left in this "genuinely open" list — see Phase 2 below for the full detail on each.

**Separately, a full pre-1.0 security/correctness audit was run today (2026-07-07)** across auth, chat/matching, and account-safety flows, ahead of submission. Found and fixed 12 real bugs, all verified live and deployed: a missing block filter on Likes You, chat images never cleaned up on account deletion, OTP brute-force only rate-limited per-IP (not per-account), Report rows cascade-deleting the moderation trail instead of surviving deletion, an unhandled concurrent-swipe match-creation race, zero rate limiting on WebSocket chat messages, no server-side floor on minimum photo count, iOS Keychain tokens surviving into device backups, refresh tokens never rotating, an unbounded 401-retry recursion, a typing indicator with no timeout, and chat not resyncing after a socket reconnect. Full details in that commit's message.

---

## Phase 1 — Before App Store Submission (P0)

**All five items resolved (2026-07-05).** Nothing code-related was ever blocking here — the remaining work was all human decisions or App Store Connect UI steps.

1. ~~Swap the placeholder app icon~~ — **keeping the current icon**, it's the real one now, not a placeholder to be replaced.
2. ~~Real on-device Sign in with Apple test~~ — **confirmed working** on a real device with a real Apple ID.
3. ~~App Store Connect's privacy nutrition label~~ — **done in App Store Connect → your app → App Privacy** (left sidebar, not under a version page — it's its own top-level section per app). Click "Get Started"/"Edit", then walk the questionnaire using the data-collection audit already in the Privacy Policy: email, phone, date of birth, gender identity, precise location (used for distance, never shown to others), photos, verification selfie, bio/prompt text, push token. No third-party analytics/ad SDKs, so those categories are "not collected."
4. ~~Real legal review~~ — **declined**, not doing this before launch.
5. ~~Confirm production admin + test/review account exist~~ — **confirmed working** in production.

---

## Phase 2 — Production Hardening (P1)

**Worked overnight (2026-07-05) while you slept — four of six items resolved**, everything verified for real, not just implemented:

- ~~Investigate the recurring Redis `ETIMEDOUT` pattern~~ — **root-caused, no code change needed.** Confirmed via production logs: zero occurrences in 26+ minutes of real activity after a restart settles, and `redis-cli INFO` showed Redis itself completely healthy the whole time (no rejected connections, no memory pressure, no restarts). Every occurrence lines up exactly with the ~2-minute CPU-saturated window while the worker loads the NSFWJS model on this box's single vCPU — a loopback TCP connect briefly can't get scheduled during that window. ioredis's default retry/reconnect already handles it with no confirmed job loss. **Restart-time-only, not a steady-state issue** — deprioritized rather than chasing a fix for something not causing real damage.
- ~~Backups: verify the restore path~~ — **found a bigger gap than expected: backups didn't exist at all.** No crontab, no `~/backups/` directory — `DEPLOYMENT.md` §12's cron job had been documented but never actually run on the server. Fixed: cron installed, a real backup taken immediately (not waiting for 3am), and the full restore path genuinely verified — downloaded the actual production dump, restored it into a scratch database, and confirmed **every table's row count matched production exactly** (User, Photo, Match, Message, AdminUser). Not "the command didn't error," actually byte-for-byte verified.
- ~~iOS automated tests~~ — **done, a real test target exists now and all tests pass.** `LumenTests.xctest` added to the Xcode project (via the `xcodeproj` gem — hand-editing this project's non-synchronized `.pbxproj` directly is too error-prone for a whole new target). `APIServiceDecodingTests.swift` (9 tests) exercises the app's actual `JSONDecoder` configuration — not a reimplementation of it — against real backend response shapes: fractional and non-fractional ISO8601 dates, malformed dates, Message/Photo/User/Match decoding, and the `needsOnboarding` logic. `AuthenticationManagerTests.swift` (5 tests) is intentionally integration-style rather than a mock-based unit test: `AuthenticationManager` is a singleton hard-wired to real `APIService`/`KeychainManager`/`SocketManager` calls with no injected seams, and refactoring core auth code for mockability unsupervised overnight was judged riskier than it was worth — these tests instead exercise real login/logout/loadCurrentUser state transitions against the real local dev backend, using one of `prisma/seed.ts`'s seeded accounts. Forces `BackendEnvironmentStore` to `.local` in `setUp` so a test run can never accidentally hit production regardless of the simulator's saved state. All 14 tests verified passing via a real `xcodebuild test` run, and both Debug and Release app builds reconfirmed clean afterward.
  - ~~`lumen.xcodeproj` gitignored~~ — **resolved (2026-07-07): now tracked.** `project.pbxproj`, the workspace's `contents.xcworkspacedata`, and the shared `MyApp.xcscheme` (whose Test action is what makes `xcodebuild test` reproducible on a fresh clone) are committed; per-user state (`xcuserdata/`, `WorkspaceSettings.xcsettings`) stays ignored. Verified a clean build still succeeds post-commit.
- ~~S3 (or equivalent) for photo storage~~ — **decision made (2026-07-07): staying on local disk.** Accepted as sufficient for current scale; revisit if/when real volume or multi-server deployment makes the single-VPS storage gap actually bite. `getPresignedUrl()` in `storage.ts` still has the seam for a one-line swap later if that changes.
- ~~Managed Postgres + Redis~~ — **decision made (2026-07-07): staying self-hosted on the droplet.** Accepted single-point-of-failure tradeoff at current scale; revisit if the user base or team grows enough that the risk changes.
- **Secrets management** — a real `.env` file on the server is fine for now, not for a team beyond one person; revisit if the admin team grows.
- **Keep this roadmap current** — it went stale for two days during heavy feature work last time; worth a standing habit of updating it in the same sitting as any P0/P1 fix, not as a separate cleanup pass.

---

## Phase 3 — Fast-Follow / QoL (P2, v1.1–1.2)

**All six items done (2026-07-05, overnight while the account holder was out)** — three quick decisions were needed and made explicitly before starting (see below), everything else built and verified live against a real running backend, not just typechecked.

**Decisions made before starting** (asked directly, answered, then executed):
1. Onboarding analytics — **self-hosted only**, no third-party SDK (the Privacy Policy already states none exist; a real analytics tool would have contradicted that).
2. Undo-last-swipe when the swipe already caused a match — **blocked**, not allowed to auto-unmatch (avoids silently vanishing a match the other person already knows about).
3. Chat image moderation — **skipped deliberately**, sent instantly with no NSFW pipeline (chat images are only ever seen by an already-matched, already-conversing recipient — a different exposure level than Discovery's stranger-facing profile photos).

- ~~Typing/online-status UI polish~~ — **done.** `SocketManager` already tracked `typingUsers`, just had no UI consuming it; added a debounced send (stops after 3s idle or on send) and an animated `TypingIndicatorBubble` (built on `TimelineView`, not a manual `Timer`, so there's nothing to leak/invalidate across appear/disappear). Online status needed a new backend field: `GET /matches` now returns `isOnline` (same Redis key the socket layer already sets) and `lastActiveAt` per match; `MatchListView` shows a green dot on the avatar or "Active Xh ago".
- ~~Read receipts UI polish~~ — turned out to be **fully unbuilt**, not just needing polish: `SocketManager`'s `"messages_read"` case was a literal no-op. Added a `lastReadReceipt` published property and wired `ChatView` to mark the sender's own messages read and show "Read" under the most recent one.
- ~~Message image sending UI~~ — also **fully unbuilt**: no upload endpoint, no picker. Built `POST /matches/:matchId/messages/photo` (multipart, uploads and creates the message in one call, stored in its own `chat/{matchId}/` tree via a new `uploadChatImage()`) and a `PhotosPicker` button in `ChatView`. Also had to relax `sendMessageSchema`'s `imageUrl` from `.url()` to a plain string — every image URL in this app, including profile photos, is actually a host-relative path resolved client-side, not a real absolute URL, so the original validation would have rejected every real image message.
- ~~Undo last swipe~~ — new `DELETE /swipe/last`, verified both the allowed path (no match yet) and the blocked path (already matched) against a real running server. `DiscoveryView`'s card stack already worked by index rather than removing cards, so undo is just decrementing `currentIndex` back by one.
- ~~Onboarding drop-off analytics~~ — new `OnboardingEvent` model (one row per "user reached this step"), logged from `OnboardingView.swift`'s two existing chokepoints (`advance()`/`finish()`, no per-step-view changes needed), a new `analytics` admin permission, and a funnel view in the admin panel (`GET /admin-tools/onboarding-funnel`, counts distinct users per step). Verified live with a simulated 5→4→3→2→1→1→1→1 drop-off.
- ~~Report reason follow-up notice~~ — reporter gets a notification (socket if online, push if offline) once their report is actioned, deliberately with no detail on what action was taken — matches the existing no-preference-toggle pattern already used for photo moderation outcomes.

Also verified as a side effect of this work: all 14 `LumenTests` still pass, and both Debug/Release app builds are clean.

---

## Phase 4 — New Features & Differentiation (P3, post-launch)

Bigger bets. Sequence based on real usage/retention data after v1.0-1.1, not pre-committed. First half is dormant capability already carried forward from before; second half is new ideas worth considering now that the admin system, moderation pipeline, and core social loop are all solid.

### Already-scaffolded, just needs UI
- **Targeted-like revival, done differently** — `Swipe.likedPhotoId`/`likedPromptNumber`/`message` already support liking a specific photo or prompt with a comment; it fought the plain swipe gesture when tried on the discovery card and was pulled. Worth revisiting as its own interaction — e.g. a "comment on this answer" option from the **Likes You** detail view, which doesn't compete with swiping at all.
- **Super Like** — `Swipe.direction` already includes `super_like` and match logic already treats it as match-triggering server-side; there's just no iOS button for it yet. Small lift, natural low-cost engagement lever.

### New ideas worth considering
- **"Liked you back" resurfacing** — someone you passed on who later likes you anyway could resurface in a dedicated queue (common Hinge/Bumble pattern). No schema change: it's a query over existing `Swipe` rows (their `like` on you + your `pass` on them), not new data.
- **Shared-tags compatibility signal** — `Tag`/`User.styleTags` already exist as a shared taxonomy; showing "3 shared tags" on a card is a cheap, honest compatibility signal that uses data the app already collects, no new infra.
- **"What's working" prompt insights** — since a like can already reference `likedPromptNumber`, a user could see which of their two prompts actually gets liked more — a small, private feedback loop that costs nothing new to build and might meaningfully improve profile quality across the app.
- **Verified-only discovery mode** — `isVerified` already exists and verified-only is already a listed filter; consider promoting it to a persistent one-tap safety toggle rather than a per-session filter, for users who specifically want to reduce catfishing exposure.
- **In-app safety check-in** — share a match's profile + your live location with a trusted contact before meeting in person, with a check-in prompt after. A genuine differentiator that fits the app's existing safety-forward positioning (the landing page already leads with "real moderation," not a bolt-on feature).
- ~~Liveness check for verification~~ — **done (2026-07-07):** camera-only capture plus a random pose prompt (peace sign, thumbs up, hand on chin, etc.) required to appear in the selfie, verified by the same human reviewer. Still not a full Rekognition `CompareFaces` auto-approve — that's the separate Open Question below.
- **Self-service data export** — a "download my data" button alongside the existing self-service account deletion; relatively cheap now that the full data model is well understood, and increasingly expected for privacy-conscious users.
- **Admin analytics view** — now that there's a real permissioned admin team, a lightweight metrics tab (signups/day, match rate, report volume trend) is a natural next investment rather than everyone working from raw intuition.
- **Notification digest option** — extends the existing 15-minute per-like notification cooldown into an opt-in daily/weekly email digest for lower-intensity users, rather than an all-or-nothing instant-push default.
- **Profile "boosts"** — temporary discovery-priority, the natural first monetization hook if/when a Pro tier is greenlit (spec deliberately keeps v1 free).
- **Pro tier / subscriptions** — StoreKit 2, paywall, feature gating (candidates: boosts, super likes, "who viewed you"). No code exists yet; scope only once there's an actual monetization decision.
- **Icebreaker prompts in chat** — curated or AI-suggested conversation starters for new matches, addressing the classic "matched but never messaged" problem.
- **Video prompts** — short video responses alongside the two text prompts; meaningful iOS media-handling lift (recording, compression, storage cost), a real differentiator vs. static-photo-only competitors.
- **Community/events feature** — speculative; gauge real user demand before building.
- **Referral/invite system** — a growth lever once there's a real user base worth growing.
- **Web companion app** — read/reply to matches from a browser; only worth it once mobile retention data justifies the investment.

---

## Suggested Sequencing

```
Phase 1 (P0)  ── DONE. Ready to submit whenever you are.
Phase 2 (P1)  ── DONE. Redis investigation, backups restore test, iOS tests, xcodeproj tracking
                  all resolved; S3 and managed Postgres/Redis deliberately deferred (staying
                  self-hosted/local-disk at current scale, revisit later if that changes).
Phase 3 (P2)  ── DONE (all six items). Ready to ship whenever you want, no need to wait for v1.1.

Post-Launch
  Phase 4 (P3 new features)── v1.3+, driven by retention/engagement data and any monetization decision
```

---

## Open Questions (need a decision, not just an estimate)

1. **Manual vs. automated verification review** — is a Rekognition face-compare auto-approve threshold acceptable, or does every verification need human eyes indefinitely? Affects how much the admin team's Verification queue scales with user growth.
2. **Monetization timing** — is there a target trigger for Phase 4's Pro tier, or is it fully deferred until post-launch metrics justify it? Affects how much to future-proof the schema now vs. later.
3. **Admin team size/structure** — the permission system supports an arbitrary team now; is there an actual plan to bring on moderators beyond the founder, or is this built ahead of need? Fine either way, just worth being intentional about.
4. ~~Should `lumen.xcodeproj` start being tracked in git?~~ — **decided (2026-07-07): yes, now tracked.** See Phase 2 above.
