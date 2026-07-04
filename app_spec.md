# Lumen — Feminine-Focused Dating App
## Product & Technical Specification v1.1

> **How to use this doc:** Paste or upload this into a new chat with Claude Code, in the root of your Xcode project (or an empty folder if starting fresh). Tell it to read this spec fully before writing any code, then build phase by phase (see Section 9).

---

## 1. Product Overview

**Concept:** An iOS dating app that is **fem-for-fem only** — every profile on the app is a feminine-presenting person (femboys, women, trans women, nonbinary feminine folks, etc.), and everyone matches with everyone else on the app, regardless of specific gender label. There is no "looking for men" option and no masculine-presenting profiles at all. This is not a filter on top of a general app — feminine presentation is the entry requirement for having a profile in the first place.

**Core differentiator:** Standard "expected" features (seeing who liked you, unlimited swipes, basic filters) are free for everyone. Monetization is secondary to building a functional, trusted product — Pro tier (if/when built) will sell visibility and convenience features, not access to core functionality.

**Platform:** iOS only for v1. Swift + SwiftUI.

**Matching model:** Swipe-based (like/pass), mutual-match required to unlock chat. Open messaging (per your requirement) means: once matched, no further gating — no "who messages first" restriction, no read-receipt paywall, no message limits. A mutual match is still the unlock condition; there is no unmatched/cold messaging.

**Enforcement of the fem-only requirement:** Self-reported at signup (Section 2), no photo review gate. This is the lightest-friction option but means enforcement happens after the fact — via reports and moderation review — rather than at the door. Worth revisiting once you have real usage: if enforcement becomes a problem, a lightweight photo-review step can be added later without a major rebuild, since it just adds a `pending_review` status before a profile goes live.

---

## 2. Identity & Taxonomy

This is the foundation of the matching system — get this right first.

**Core rule: there is no "looking for" field.** Every profile on the app is feminine-presenting, so every profile is a potential match for every other profile (subject to age/distance filters only, Section 3.3). This removes an entire layer of matching complexity compared to a general dating app. (Discovery does support an optional *display filter* — e.g. "only show me femboys" — but that is a per-session viewing preference, not a stored compatibility field on the profile itself; see Section 3.3.)

### 2.1 Gender Identity (profile field, single-select + "other, specify" free text)
- Woman
- Femboy
- Trans woman
- Nonbinary (feminine-leaning)
- Other (free text)

This field is for self-expression and how a user's profile displays to others — it is **not** used to gate who can sign up (see 2.2) and **not** used to filter matches (there's no opposite-gender exclusion logic needed here).

### 2.2 Signup Gate (self-reported)
At signup, a single required checkbox/attestation: *"This app is for feminine-presenting people. By continuing, you confirm you identify as feminine or present as feminine."* No photo review, no ID check — this is an honor-system gate, enforced after the fact via reporting/moderation (Section 3.7) rather than at the door. Flag clearly in your Terms of Service that misrepresenting this is a bannable offense, since that's your actual enforcement mechanism, not the checkbox itself.

### 2.3 Optional profile expression fields
- Style/vibe tags (e.g. "soft goth," "sporty," "gamer girl," "cottagecore") — fully open, any user can create a new tag on their own profile immediately (no approval queue). Tags get reused/discovered organically as more users adopt existing ones (like Instagram hashtags). Worth adding basic profanity/abuse filtering on tag creation even though the system itself is unmoderated, so it doesn't become a harassment vector. Tags are stored as a shared, reusable taxonomy (Section 5) rather than free text per profile, so they can be searched/browsed/autocompleted as adoption grows.
- Pronouns (free text, defaults suggested: she/her, they/them)

---

## 3. Core Features (Full Build — Phase Everything)

### 3.1 Authentication
- Email + password, plus Sign in with Apple (required by App Store guidelines if you offer any other third-party login, and good practice regardless)
- Phone number verification (SMS OTP) at signup to reduce bot/fake accounts
- Age gate: 18+ only, hard requirement, ID-adjacent verification optional (see 3.6)

### 3.2 Profile
- Photos: minimum 1, max 6, drag-to-reorder
- Bio (free text, character limit ~500)
- Gender identity, pronouns, style tags (Section 2)
- Height (optional, stored as total inches; displayed as a feet/inches picker)
- Job title, school (both optional free text)
- Prompts: up to 2, each a (question, answer) pair where the question is chosen from a fixed
  preset list (Hinge-style) and the answer is free text (~300 chars) — the preset list is
  duplicated by hand on both backend (`PROMPT_QUESTIONS` in validation.ts) and iOS
  (`PromptQuestion.allCases` in Models.swift) since there's no shared codegen between them
- Age (calculated from DOB, not user-entered directly, to prevent easy lying)
- Location (city-level display, precise geolocation used only for distance calculation, never shown to other users)

### 3.2a Onboarding (post-signup, pre-discovery)
Right after phone verification, before the user reaches the main app, a short guided flow collects
the profile fields needed to actually use the app — matching the "ask a series of questions" pattern
common to dating apps, rather than dropping the user into a blank profile.
- **Mandatory steps:** location (required — discovery cannot function without it, see 3.3) and at
  least 1 photo (matches the minimum-photo requirement above).
- **Skippable steps:** bio/pronouns, height, job/school, prompts, style tags — collected here for
  convenience but also editable later from Settings, so skipping doesn't lock anyone out.
- Steps after the first (location) have a back button; location itself doesn't, since going back
  from it only leads to the auth flow.
- Runs once; a user who already has a location and a photo (e.g. a returning user, or a fresh
  install re-authenticating into an existing account) skips straight to the main app.

### 3.3 Discovery / Swipe
- Card-stack swipe UI: whole-card drag left/right = pass/like. The whole card — every photo and
  the info below it — scrolls vertically as one continuous feed (Hinge-style), while horizontal
  drags are still read as the pass/like decision; the gesture is disambiguated by which direction
  dominates a drag, biased toward "it's a scroll" unless the drag is clearly horizontal.
- Filter by: age range, distance radius (miles), height range, verified-only, gender identity
  (v1 feature — e.g. "only show femboys" — this is a preference filter, not a two-way
  compatibility gate, since every profile remains a valid match for every other profile)
- Matching logic pulls candidates where: within distance radius AND within age/height range AND
  not already swiped AND not blocked AND (if filters set) matches gender identity / verified-only
- Daily like limit: **none** (per your requirement — this stays free/unlimited regardless of monetization later)
- The backend can associate a like with a specific photo/prompt and an optional comment
  (`Swipe.likedPhotoId` / `likedPromptNumber` / `message`), and `LikesYouView` can display that
  context if present — but there's currently no UI action that creates one (tried as a "like this
  specific photo" affordance on the discovery card; removed in favor of plain whole-card
  swiping, which read better). Left in place as dormant capability, not dead code to rip out.
- "Who liked you" — its own tab (`LikesYouView`), visible to all users, free, no paywall (per
  your requirement). Shows what was specifically liked (a photo, a prompt, or the profile
  generally) and any comment; tapping a card lets you like or pass back, matching instantly on
  like since they already liked you.

### 3.4 Matching
- Mutual like = match, both users notified
- Match list screen showing all current matches with last-message preview

### 3.5 Chat (Open Messaging)
- Real-time messaging via WebSockets (Socket.io)
- Text messages open immediately once matched
- Image messages unlock after a short text exchange (recommend: 3–5 messages exchanged between both users) — this is a lightweight anti-scam/anti-harassment friction point, common on dating apps to cut down on unsolicited image sending. Working default: **3 messages** (see Section 10).
- Read receipts — free, no paywall (per your "don't limit normal stuff" principle)
- Typing indicators
- Unmatch = deletes chat thread for both users
- Report/block available from any chat

### 3.6 Verification (Optional, Boosts Visibility)
- Selfie liveness check (photo matched against profile photos using a basic face-comparison service or manual review queue for MVP)
- Verification has an explicit status (not submitted / pending / approved / rejected) so a review queue can actually be built off it — see Section 5
- Verified badge on profile
- Verified profiles get a discovery boost (appear higher in swipe decks) — this is the intended incentive structure, not a paywall gate

### 3.7 Safety & Moderation
- Report user (with reason categories: harassment, fake profile, misrepresenting gender presentation, inappropriate content, underage suspicion, other)
- Block user — hides both users from each other's discovery and search entirely, not just chat
- Screenshot detection in chat is NOT reliable on iOS and shouldn't be promised as a feature
- **Consequence policy:** confirmed violations (including misrepresenting fem presentation to bypass the signup gate, Section 2.2) result in a temporary suspension with an appeal process — not an instant permanent ban. Appeal flow can be simple for MVP (e.g. a support email reviewed manually), formalized later.
- **Moderation queue for MVP:** reviewed manually by you (the founder) — no dedicated admin team needed at this scale, but the backend should still have a proper admin-only endpoint/dashboard for this rather than querying the database directly. Every report needs an audit trail — who reviewed it, what action was taken, and when (see `Report` model, Section 5) — even as a solo reviewer.
- Photo moderation: automated NSFW detection on upload (e.g. AWS Rekognition or similar) to catch obviously non-compliant content before it's visible to others, in addition to your manual report review

### 3.8 Notifications
- Push notifications (APNs) for: new match, new message, new like — instant push for all three per your preference. Worth keeping an eye on this post-launch: instant-per-like pushes can get noisy for popular profiles, so consider a user-facing toggle to switch to batched later even if instant is the default.

### 3.9 Settings
- Edit profile, notification preferences, block list management, account deletion (required by App Store — must be self-service, not "email support to delete"), privacy settings (who can see "last active," discovery on/off toggle)

---

## 4. Tech Stack

### 4.1 iOS App
- **Language:** Swift
- **UI:** SwiftUI
- **Networking:** URLSession or Alamofire, async/await
- **Real-time:** Socket.io-client-swift for chat
- **Image handling:** PhotosUI for picker, Kingfisher or native AsyncImage for loading/caching
- **Local storage:** Keychain for auth tokens, no sensitive data in UserDefaults

### 4.2 Backend
- **Runtime:** Node.js with TypeScript
- **Framework:** Fastify — chosen over Express for the lighter footprint and first-class TypeScript support; this is the stack the codebase is built against, not an open choice anymore.
- **Database:** PostgreSQL
- **ORM:** Prisma
- **Real-time:** Socket.io
- **Cache/session:** Redis (session tokens, rate limiting, online-status tracking)
- **File storage:** S3-compatible object storage (AWS S3, or Cloudflare R2 for lower cost) for photos in production; falls back to local disk storage when AWS credentials aren't configured, so local dev doesn't require a real AWS account
- **Auth:** JWT access + refresh tokens, Argon2 for password hashing
- **SMS OTP:** Twilio in production; falls back to console-logged codes when Twilio credentials aren't configured, so local dev doesn't require a real Twilio account

### 4.3 Infrastructure
- **Apple Developer Program:** not yet enrolled — sign up at developer.apple.com ($99/yr) before you need TestFlight or App Store submission. Not needed for early local development/simulator work, but you'll want it enrolled before Phase 8 (Section 9), and ideally earlier since APNs push notifications also require a paid account.
- **API hosting:** Railway, Render, or Fly.io for easy MVP deployment (skip AWS/GCP complexity until you have real usage)
- **Push notifications:** APNs via a wrapper service (or direct HTTP/2 APNs calls)
- **SMS OTP:** Twilio or similar (see 4.2 for local-dev fallback)
- **Photo moderation:** AWS Rekognition (pay-per-use, no infra to manage) or open-source alternative if cost is a concern at low volume

---

## 5. Data Models (initial schema sketch)

```
User
  id, email, phone, password_hash, created_at
  date_of_birth, gender_identity, fem_attestation_accepted (bool, timestamp)
  bio, pronouns, height_inches (nullable), job_title (nullable), school (nullable)
  prompt1_question, prompt1_answer, prompt2_question, prompt2_answer (all nullable)
  is_verified, verification_photo_url, verification_status (none/pending/approved/rejected)
  verification_reviewed_by (nullable, -> User.id), verification_reviewed_at (nullable)
  latitude, longitude, city_display
  is_active, last_active_at
  discoverable (bool)
  is_admin (bool, default false) — flags founder/admin accounts for the moderation dashboard

Photo
  id, user_id, url, order, moderation_status

Tag
  id, name (unique), created_at
  — catalog of every tag name ever used, upserted whenever a user adds a new tag to their profile.
    Powers autocomplete/browsing (Section 2.3). The user's own selected tags still live as a plain
    string array on User.style_tags for fast reads; Tag exists only to know what tags exist across
    the app, not to model the user↔tag relationship (a full join table is a v2 optimization if
    tag-based search/filtering becomes a real feature).

Swipe
  id, swiper_id, swiped_id, direction (like/pass), created_at
  liked_photo_id, liked_prompt_number (1 or 2), message (all nullable — targeted-like context,
    Section 3.3; liked_photo_id is a loose reference, not a formal FK, so a like's record of what
    was liked doesn't need cascade-handling if the photo is later deleted)
  — unique constraint on (swiper_id, swiped_id)

Match
  id, user_a_id, user_b_id, created_at, unmatched_at (nullable)

Message
  id, match_id, sender_id, content, image_url (nullable), created_at, read_at (nullable)

Report
  id, reporter_id, reported_id, reason, details, status (pending/reviewed/actioned), created_at
  reviewed_by (nullable, -> User.id), reviewed_at (nullable), action_taken (nullable)
  — audit trail fields so the admin dashboard (3.7) can show who actioned what, when

Block
  id, blocker_id, blocked_id, created_at
```

---

## 6. Key API Endpoints (sketch)

```
POST   /auth/signup
POST   /auth/verify-otp
POST   /auth/login
POST   /auth/refresh

GET    /profile/me
PATCH  /profile/me
POST   /profile/photos
DELETE /profile/photos/:id

GET    /discovery/stack        // returns candidate profiles per filters
POST   /swipe                  // { swiped_id, direction }

GET    /matches
GET    /matches/:id/messages
POST   /matches/:id/messages
DELETE /matches/:id            // unmatch

POST   /reports
POST   /blocks
DELETE /account                // self-service deletion, required by App Store
```

Real-time events (Socket.io) layered on top for message delivery, typing indicators, and online status — REST for everything else.

---

## 7. Matching Algorithm (v1, simple)

1. Pull all active, discoverable profiles (no gender cross-matching needed — see Section 2)
2. Filter by distance (Postgres with PostGIS extension, or simple lat/long bounding box for MVP)
3. Filter by age range preference (both directions)
4. Exclude already-swiped, blocked, and inactive (>90 days) users
5. Optional: apply gender-identity display filter if the user has one set (e.g. only show femboys) — this is a preference filter, not a compatibility gate
6. Order by: verified status (boost) > recently active > random shuffle within tiers

This is intentionally simple for v1 — no ML ranking yet. That's a v2+ concern once you have real usage data.

---

## 8. Non-Functional Requirements

- **Privacy:** Precise location never exposed to other users, only city-level + distance. Photos stored privately, served via signed URLs, not public S3 links.
- **Security:** Rate limiting on swipe/message endpoints to prevent scraping/spam. Input sanitization on all user-generated content. HTTPS everywhere.
- **App Store compliance:** Self-service account deletion, clear content moderation policy, age gate, EULA covering user-generated content (Apple requires this for apps with UGC + messaging — you'll need a way to block/report and act on it, which this spec already includes).
- **Scalability:** Not a v1 concern — build for correctness first, revisit scaling when you have real signups.

---

## 9. Suggested Build Phases (for Claude Code to work through in order)

1. **Backend foundation:** Project setup, Postgres + Prisma schema, auth endpoints (signup/login/JWT), basic profile CRUD
2. **iOS foundation:** Project setup, auth flow UI, profile creation/edit UI
3. **Discovery + Swipe:** Backend candidate endpoint + matching filter logic, iOS swipe-card UI
4. **Matching + Chat:** Match creation on mutual like, Socket.io real-time chat, iOS chat UI
5. **Safety layer:** Report/block endpoints and UI, photo moderation integration
6. **Verification:** Selfie upload + review flow, verified badge, discovery boost logic
7. **Notifications:** APNs integration for match/message pushes
8. **Settings + polish:** Account deletion, privacy toggles, edge-case handling, App Store submission prep

---

## 10. Open Questions to Resolve Before/During Kickoff

- Exact message-count threshold before image messages unlock in chat (Section 3.5) — **resolved: 3**, easy to change later.

All other open items from earlier drafts have been resolved and folded into the relevant sections above. App name is **Lumen** — bundle ID is `com.camdenheil.lumen`.
