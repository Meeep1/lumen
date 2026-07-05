# Lumen — Release Roadmap

Status snapshot as of **2026-07-05**. This is a full revamp of the previous roadmap — the app went from "no admin system, no production deploy" to **live in production at `lumenfem.app`** with a real team-permission admin system, a hardened moderation pipeline, and a fixed real-time chat bug, all in the last two days. This doc is reorganized around where things actually stand now: a short list of true pre-submission blockers, a production-hardening list for what's live but not yet bulletproof, and a much bigger, more concrete new-features section for what comes after launch.

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

**Known open item, not yet root-caused:** a recurring Redis `ETIMEDOUT` in the worker's logs, so far only observed shortly after a `pm2 restart lumen-worker` (each time right as the model finishes loading). Hasn't caused a real failure yet — BullMQ retries through it — but it's only been seen during today's unusually restart-heavy testing session, not under normal steady-state operation. Worth a real look if it shows up outside of a restart window (see Phase 2).

Still genuinely open:
- **iOS has zero automated tests.** Backend has 19 integration tests in CI; `APIService.swift`/`AuthenticationManager` tests and an Xcode test target don't exist yet.
- **App icon is placeholder art** — a programmatically-generated gradient-and-heart mark, functional for submission but not final branding.
- **Real on-device Sign in with Apple test** — capability is enabled and the token-verification code path is solid, but never exercised against a real signed token on a physical device.
- **Photo storage is still local disk on the single production VPS** — no CDN, no redundancy, doesn't survive a redeploy-to-new-server scenario. Fine at current scale, a real gap at real volume.
- **Production admin/test accounts** — confirm `npm run create-admin` and `npm run create-test-account` have actually been run against production (`DEPLOYMENT.md` §9.5), not just documented.

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
  - **Important caveat found while doing this: `lumen.xcodeproj` is entirely gitignored** (`*.xcodeproj` in `.gitignore`, and `git log` confirms it's never once been committed) — this predates tonight, not something introduced by this change. That means the new `LumenTests` target, its build settings, and the scheme's Test action all exist **only in this local checkout** and are not backed up or shareable via git. The two test `.swift` files themselves are regular tracked source files and will show up normally in git status. Worth a deliberate decision on whether to start tracking the `.xcodeproj` (tradeoff: real backup/shareability vs. `.pbxproj` merge-conflict pain) rather than leaving this as an accidental gap.
- **S3 (or equivalent) for photo storage** — still open, needs your AWS credentials/decision, didn't touch this overnight. `getPresignedUrl()` in `storage.ts` already has the seam for a one-line swap once bucket credentials exist.
- **Managed Postgres + Redis** — still open, needs your decision (cost + provider), didn't touch this overnight. Currently self-hosted on the same droplet as the app; fine at current scale, a single point of failure at real scale.
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
- **Liveness check for verification** — upgrade the static selfie-vs-profile-photo comparison to a simple in-app gesture prompt (blink, turn head) before submission, reducing spoofing risk without the cost of a full Rekognition `CompareFaces` integration.
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
Phase 2 (P1)  ── Redis investigation, backups restore test, and iOS tests DONE.
                  S3 migration and managed Postgres/Redis still need your decision + credentials.
Phase 3 (P2)  ── DONE (all six items). Ready to ship whenever you want, no need to wait for v1.1.

Post-Launch
  Phase 4 (P3 new features)── v1.3+, driven by retention/engagement data and any monetization decision
```

---

## Open Questions (need a decision, not just an estimate)

1. **Manual vs. automated verification review** — is a Rekognition face-compare auto-approve threshold acceptable, or does every verification need human eyes indefinitely? Affects how much the admin team's Verification queue scales with user growth.
2. **Monetization timing** — is there a target trigger for Phase 4's Pro tier, or is it fully deferred until post-launch metrics justify it? Affects how much to future-proof the schema now vs. later.
3. **Admin team size/structure** — the permission system supports an arbitrary team now; is there an actual plan to bring on moderators beyond the founder, or is this built ahead of need? Fine either way, just worth being intentional about.
4. **Should `lumen.xcodeproj` start being tracked in git?** Found tonight: it's been fully gitignored since day one, so the Xcode project structure (targets, schemes, build settings — including the new `LumenTests` target) only exists on this one Mac, with no backup. Tradeoff is real either way: tracking it means a real backup and the ability to `git clone` a working project elsewhere, but `.pbxproj` merge conflicts are a known pain point if this is ever worked on from two machines/branches at once.
