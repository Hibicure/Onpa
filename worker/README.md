# Otocloud relay (Cloudflare Worker `geocloud`)

Deployed at https://geocloud.icchasong.workers.dev

Secrets (set in Cloudflare → geocloud → Settings → Variables and Secrets, never in this file):
- `SC_CLIENT_ID`, `SC_CLIENT_SECRET` — SoundCloud app
- `LK_API_KEY`, `LK_API_SECRET` — LiveKit

Routes: `/search`, `/play`, `/livekit-token`, `/sc/login`, `/sc/callback`, `/sc/refresh`, `/sc/me`, `/sc/likes`, `/sc/playlists`, `/sc/playlist`, `/sc/like`
