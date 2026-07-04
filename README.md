# Lumen — Feminine-Focused Dating App

A fem-for-fem-only iOS dating app: Swift/SwiftUI client + Node/TypeScript/Fastify/Prisma backend.
Full product spec: [app_spec.md](app_spec.md).

## Project structure

```
backend/                     Node.js/TypeScript API
  prisma/schema.prisma       Database schema
  src/
    routes/                  REST endpoints (auth, profile, discovery, swipe, match, report, block)
    socket/handlers.ts       Socket.IO real-time chat
    middleware/auth.ts       JWT auth guard
    utils/                   validation (zod), auth (argon2/JWT), sms, storage
    server.ts                Fastify app entry point

Lumen/                       iOS app (Xcode target: MyApp, bundle id com.camdenheil.lumen)
  App/LumenApp.swift         App entry point
  Models/Models.swift        Codable models shared across the app
  Services/                  APIService, KeychainManager, SocketManager, AuthenticationManager
  Views/{Auth,Discovery,Matches,Profile}/  SwiftUI views
```

## Status

Backend (Phases 1–5 of app_spec.md Section 9 — auth, profile, discovery/swipe, matching/chat,
report/block) is implemented, typechecks clean, and has been verified end-to-end against a local
Postgres + Redis (signup → OTP verify → login → profile read/update → discovery). Phases 6–8
(verification, push notifications, settings polish) are not built yet.

iOS views exist for all of the above (auth flow, swipe cards, match list, chat, profile/settings),
wired to the backend via `APIService`. Socket.IO client integration is stubbed — see "Known gaps"
below.

## Local development

### Backend

Requires Node 18+, PostgreSQL, Redis running locally (no AWS/Twilio account needed — see below).

```bash
cd backend
npm install
cp .env.example .env        # defaults assume a local `lumen` database owned by your Mac user
createdb lumen               # if it doesn't already exist
npm run prisma:migrate
npm run dev                  # http://localhost:3000
```

In local dev mode, SMS OTP codes are printed to the server console instead of sent via Twilio, and
uploaded photos are saved to `backend/uploads/` instead of S3 (see `src/utils/sms.ts` and
`src/utils/storage.ts`). Swap these back to Twilio/S3/Rekognition before deploying — the commented
production code is left in place in both files.

### iOS

Open `Untitled Project.xcodeproj` in Xcode. The app points at `http://localhost:3000` by default
(`Lumen/Services/APIService.swift`); update `baseURL` there if testing on a physical device.

**One-time setup:** this machine hasn't accepted the Xcode license yet — run
`sudo xcodebuild -license` in Terminal once before building.

## Known gaps

- **Socket.IO client isn't wired up.** `Lumen/Services/SocketManager.swift` has the real
  implementation commented out pending adding the `socket.io-client-swift` SPM package
  (File > Add Package Dependencies → `https://github.com/socketio/socket.io-client-swift`,
  16.0.0+). Until then, chat falls back to REST-only (messages send/load via `APIService`, no
  live push or typing indicators).
- Photo upload UI (`Lumen/Views/Profile/ProfileView.swift`) has a placeholder "add photo" button
  with no picker wired up yet.
- Account deletion, verification (selfie/face-match), and push notifications are not built
  (Phases 6–8).
