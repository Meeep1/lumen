import * as Sentry from '@sentry/node';

// No-ops safely when SENTRY_DSN is unset (local dev without a Sentry project configured) —
// the SDK treats a missing/empty dsn as "disabled" rather than throwing, so every call site
// that captures an exception below stays a no-op instead of needing its own guard.
Sentry.init({
  dsn: process.env.SENTRY_DSN,
  environment: process.env.NODE_ENV || 'development',
  tracesSampleRate: process.env.NODE_ENV === 'production' ? 0.1 : 0,
});

export { Sentry };
