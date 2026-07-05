// Minimal pm2 process manager config for production (ROADMAP.md 1.8) — dev keeps using
// `npm run dev` (tsx watch) directly, this is only for a real deploy: `pm2 start ecosystem.config.js`.
//
// Two processes, not one: `lumen-backend` (the Fastify API) and `lumen-worker` (photo
// moderation — see src/worker.ts). They're deliberately separate OS processes, not just two
// code paths in one process, because NSFWJS classification is 5-12s of *blocking* CPU work with
// no native/GPU acceleration here — running it inline on the API process used to stall every
// other user's request for that whole window on every single photo upload (see queue.ts). A
// crash or restart in one process doesn't affect the other.
module.exports = {
  apps: [
    {
      name: 'lumen-backend',
      script: 'dist/server.js',
      instances: 1,
      autorestart: true,
      max_restarts: 10,
      min_uptime: '30s',
      restart_delay: 2000,
      env: {
        NODE_ENV: 'production',
      },
      error_file: 'logs/error.log',
      out_file: 'logs/out.log',
      time: true,
    },
    {
      name: 'lumen-worker',
      script: 'dist/worker.js',
      instances: 1,
      autorestart: true,
      max_restarts: 10,
      min_uptime: '30s',
      restart_delay: 2000,
      env: {
        NODE_ENV: 'production',
      },
      error_file: 'logs/worker-error.log',
      out_file: 'logs/worker-out.log',
      time: true,
    },
  ],
};
