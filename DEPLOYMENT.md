# Deploying Lumen

How to get the backend (API + public site + admin panel) running in production on a single
cheap VPS, with a real domain and TLS. See `ROADMAP.md` Phase 3 for the broader production
readiness checklist this is part of.

**What you're deploying:** one server running three things — the Fastify API/site/admin (port
3000, behind Caddy for TLS), a separate photo-moderation worker process, Postgres, and Redis.
Two Node processes (API + worker) instead of one is deliberate: NSFWJS photo classification is
5-12 seconds of blocking CPU work, and running it in the same process as the API used to freeze
the app for every other user during that window. Keeping them separate means a photo upload
never affects anyone else. See `backend/src/queue.ts` for the full reasoning.

---

## 0. What you'll need before starting

- A server: **DigitalOcean**, since it takes PayPal (Hetzner requires a card that supports 3D
  Secure, which was a dead end) — [digitalocean.com](https://www.digitalocean.com). The
  "Basic" Droplet at **$12/mo** (Regular Intel, 2GB RAM / 1 vCPU / 50GB SSD) is the cheapest tier
  worth trusting for Postgres + Redis + two Node processes (the NSFWJS model the worker loads is
  itself a meaningful chunk of RAM) — the $6/mo 1GB tier risks swapping under real load. Vultr
  and Linode are equally good, equally cheap, and both also take PayPal, if you want to compare;
  everything from here on is identical regardless of which one you pick, since it's all just
  "an Ubuntu server" once it's running.
- The domain you've already decided on: **`lumenfem.app`**, registered (Cloudflare is a
  reasonable registrar — you already use it for `meeep.xyz`).
- An SSH key on your Mac. If you don't have one: `ssh-keygen -t ed25519` (accept the defaults).

---

## 1. Provision the server

1. Create a new Droplet:
   - Image: **Ubuntu 24.04 LTS**
   - Plan: **Basic → Regular → $12/mo (2GB/1vCPU/50GB SSD)**
   - Authentication: **SSH key** (add your public key, `cat ~/.ssh/id_ed25519.pub`) — don't use
     password auth.
2. Note the Droplet's IP address once it boots.
3. SSH in: `ssh root@<server-ip>`

### Basic hardening (do this first, before anything else)

```bash
# Create a non-root user
adduser lumen
usermod -aG sudo lumen

# Copy your SSH key to the new user
rsync --archive --chown=lumen:lumen ~/.ssh /home/lumen

# Firewall — only allow SSH, HTTP, HTTPS
apt update && apt install -y ufw
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw enable
```

From here on, log in as `ssh lumen@<server-ip>`, not root.

---

## 2. Install dependencies

```bash
# Node.js 20
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs git

# PostgreSQL
sudo apt install -y postgresql postgresql-contrib

# Redis
sudo apt install -y redis-server
sudo systemctl enable --now redis-server

# pm2 (process manager — the app already ships an ecosystem.config.js for this)
sudo npm install -g pm2
```

---

## 3. Set up Postgres

```bash
sudo -u postgres psql
```
```sql
CREATE USER lumen WITH PASSWORD 'CHOOSE_A_REAL_PASSWORD_HERE';
CREATE DATABASE lumen OWNER lumen;
\q
```

---

## 4. Get the code onto the server

```bash
cd ~
git clone <your-repo-url> lumen
cd lumen/backend
npm ci
npm run build
```

---

## 5. Configure `.env` for production

```bash
cp .env.example .env
nano .env
```

Fill in real values. Most of these already exist in your local dev `.env` — **don't just copy
that file over**; generate fresh secrets for production so a leaked dev secret never affects
production and vice versa.

| Variable | What to put |
|---|---|
| `NODE_ENV` | `production` |
| `DATABASE_URL` | `postgresql://lumen:<password>@localhost:5432/lumen?schema=public` |
| `REDIS_URL` | `redis://localhost:6379` |
| `JWT_ACCESS_SECRET` / `JWT_REFRESH_SECRET` | New values from `openssl rand -base64 32` — **not** the same ones as dev |
| `ADMIN_BASIC_AUTH_USER` / `ADMIN_BASIC_AUTH_PASSWORD` | New values, different from dev — this is what hides `/admin/` from the public |
| `APNS_KEY_ID` / `APNS_TEAM_ID` | Same as dev (`BB92QH6224` / `X64DVU8KXZ`) — it's the same Apple key regardless of environment |
| `APNS_PRODUCTION` | **`false` for TestFlight-only, `true` only once actually on the App Store.** Apple's rule is about which *provisioning profile* signed the installed build, not which server it talks to — a development-signed build always needs `sandbox` (i.e. `false`), and Apple only switches a build to the production APNs gateway once it's signed for real distribution. Get this wrong and push notifications silently fail for everyone. |
| `SMTP_*` | Same as dev (`meeep.xyz` / Purelymail credentials) |
| `RATE_LIMIT_MAX` | `100` (the original default — dev bumped this to 500 for convenience during testing; production should be tighter) |
| `APPLE_BUNDLE_ID` | `com.lumenfem.dating` |

Copy your APNs key onto the server too (don't commit it — see `.gitignore`'s `*.p8` rule):
```bash
mkdir -p ~/lumen/backend/certs
scp /Users/camdenheil/Documents/lumen/backend/certs/AuthKey.p8 lumen@<server-ip>:~/lumen/backend/certs/
chmod 600 ~/lumen/backend/certs/AuthKey.p8
```

Apply the database schema (this project uses `prisma db push`, not tracked migrations — see any
schema-related note in `ROADMAP.md` for why):
```bash
npx prisma db push
```

---

## 6. Point the domain at the server

In whichever registrar/DNS provider manages `lumenfem.app` (Cloudflare, if that's where you
registered it):

- Add an **A record**: `lumenfem.app` → `<server-ip>`
- If using Cloudflare, set that record to **DNS only** (grey cloud, not orange) for now — Caddy
  needs to complete a Let's Encrypt HTTP challenge directly against the server's real IP in the
  next step, which Cloudflare's proxy would get in the way of. You can switch it to proxied
  (orange cloud) afterward once TLS is issued, if you want Cloudflare's CDN/DDoS protection too.

DNS can take a few minutes to a few hours to propagate — `dig lumenfem.app` should show your
server's IP once it has.

---

## 7. Reverse proxy + automatic TLS with Caddy

Caddy gets you free, auto-renewing HTTPS with almost no config — much simpler than nginx +
certbot for a single-domain setup like this.

```bash
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update
sudo apt install -y caddy
```

Edit `/etc/caddy/Caddyfile` (replace the whole file):
```
lumenfem.app {
    reverse_proxy localhost:3000
}
```

```bash
sudo systemctl restart caddy
```

That's it — Caddy will automatically request and renew a Let's Encrypt certificate for
`lumenfem.app` the moment it can complete the HTTP challenge (i.e., once DNS is pointed at it).

---

## 8. Start the app

```bash
cd ~/lumen/backend
pm2 start ecosystem.config.js
pm2 save
pm2 startup   # follow the printed instructions (runs a sudo command to enable pm2 on boot)
```

This starts **both** `lumen-backend` (the API) and `lumen-worker` (photo moderation) — check
`ecosystem.config.js` if you want to confirm. `pm2 logs` tails both; `pm2 logs lumen-worker` for
just the worker.

---

## 9. Verify it's actually working

```bash
curl https://lumenfem.app/health
# {"status":"ok",...}
```

- Visit `https://lumenfem.app/` — the landing page.
- Visit `https://lumenfem.app/privacy` and `/terms` — the real legal pages.
- Visit `https://lumenfem.app/admin/` — should immediately prompt for the Basic Auth credentials
  you set in `.env` (not the Lumen admin login itself — that's the *next* gate, after this one).

If any of these fail, `pm2 logs lumen-backend` and `sudo journalctl -u caddy` are the first two
places to look.

---

## 10. Point the iOS app at production

Two places still reference the dev LAN IP — update both once this is live:

- `Lumen/Services/APIService.swift` — `baseURL` constant. Ideally make this build-configuration-
  based (Debug → LAN IP/localhost, Release → `https://lumenfem.app`) rather than a single
  hardcoded value, so you don't have to remember to flip it back for local development.
- `Lumen/Views/Profile/SettingsView.swift` — the three legal-page `Link(destination:)` URLs.

---

## 11. Deploying updates later

```bash
cd ~/lumen
git pull
cd backend
npm ci
npm run build
npx prisma db push   # only if schema.prisma changed
pm2 restart all
```

---

## 12. Backups (do this before real user data exists)

Minimal daily Postgres backup via cron:

```bash
mkdir -p ~/backups
crontab -e
```
Add:
```
0 3 * * * pg_dump -U lumen lumen | gzip > ~/backups/lumen-$(date +\%Y\%m\%d).sql.gz
```

This keeps backups on the same server, which protects against accidental data corruption but
not against losing the whole server — copy them offsite periodically (e.g. `rclone` to Backblaze
B2 or S3) once this matters for real. Also worth testing the restore path
(`gunzip -c backup.sql.gz | psql -U lumen lumen` against a scratch database) before you actually
need it.
