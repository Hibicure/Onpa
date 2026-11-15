// Cloudflare Worker - Onpa 中継役（SoundCloud 公式API ＋ LiveKit 入場券）
// 秘密の値はここに書かず、Cloudflareの「Variables and Secrets」に入れる：
//   SC_CLIENT_ID / SC_CLIENT_SECRET … SoundCloudアプリの鍵
//   LK_API_KEY / LK_API_SECRET     … LiveKitの鍵

const TOKEN_URL = 'https://secure.soundcloud.com/oauth/token';
const AUTH_URL = 'https://secure.soundcloud.com/authorize';
const API = 'https://api.soundcloud.com';

// 使えるサイト（これ以外から呼ばれても許可しない）
const ALLOWED_ORIGINS = [
  'https://on-pa.net',
  'https://onpa-e7cc6.web.app',
  'https://onpa-e7cc6.firebaseapp.com',
  'http://localhost:8000',
  'http://localhost:5000',
];

// ===================== 共通の道具 =====================
function corsHeaders(request) {
  const origin = request.headers.get('Origin');
  const allow = ALLOWED_ORIGINS.includes(origin) ? origin : ALLOWED_ORIGINS[0];
  return {
    'Access-Control-Allow-Origin': allow,
    'Access-Control-Allow-Methods': 'GET, POST, DELETE, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, X-SC-Token, Authorization',
    'Vary': 'Origin',
  };
}

function json(body, status, cors) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json; charset=utf-8', ...cors },
  });
}

function b64url(input) {
  const bytes = typeof input === 'string' ? new TextEncoder().encode(input) : new Uint8Array(input);
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function randomString(n = 48) {
  const a = new Uint8Array(n);
  crypto.getRandomValues(a);
  return b64url(a).slice(0, n);
}

function isAllowedReturn(u) {
  try { return ALLOWED_ORIGINS.includes(new URL(u).origin); } catch { return false; }
}

// SoundCloudの曲データを、アプリで使う形にそろえる
function mapTrack(t) {
  return {
    id: t.id,
    title: t.title,
    artist: t.metadata_artist || t.publisher_metadata?.artist || t.user?.username || 'Unknown',
    uploader: t.user?.username || '',
    artwork: t.artwork_url || t.user?.avatar_url || '',
    duration: t.duration,
    access: t.access,
    permalink_url: t.permalink_url,
  };
}
const listOf = (d) => (Array.isArray(d) ? d : d?.collection || []);

// ===================== アプリ用の入場券（検索・再生） =====================
// SoundCloudは入場券の発行回数に上限があるので、いったん取った券を
// Cloudflareのキャッシュに置いて、全部の処理で使い回す（有効期限が切れるまで）
let cached = { token: null, rt: null, exp: 0 };
const TOKEN_CACHE_KEY = 'https://onpa-cache.internal/sc-app-token-v1';

async function readCachedToken() {
  try {
    const hit = await caches.default.match(TOKEN_CACHE_KEY);
    if (!hit) return null;
    const d = await hit.json();
    return d && d.token && d.exp > Date.now() ? d : null;
  } catch { return null; }
}

async function writeCachedToken(d) {
  try {
    const ttl = Math.max(Math.floor((d.exp - Date.now()) / 1000), 60);
    await caches.default.put(TOKEN_CACHE_KEY, new Response(JSON.stringify(d), {
      headers: { 'Content-Type': 'application/json', 'Cache-Control': `max-age=${ttl}` },
    }));
  } catch { /* キャッシュできなくても続ける */ }
}

// 発行を断られたら、しばらく問い合わせない（何度も叩くと制限が長引くため）
const BLOCK_KEY = 'https://onpa-cache.internal/sc-token-blocked-v1';
let blockedUntil = 0;
async function readBlocked() {
  if (blockedUntil > Date.now()) return blockedUntil;
  try { const hit = await caches.default.match(BLOCK_KEY); if (hit) { blockedUntil = Number(await hit.text()) || 0; } } catch { /* 無視 */ }
  return blockedUntil > Date.now() ? blockedUntil : 0;
}
async function writeBlocked(until) {
  blockedUntil = until;
  try {
    const ttl = Math.max(Math.ceil((until - Date.now()) / 1000), 30);
    await caches.default.put(BLOCK_KEY, new Response(String(until), { headers: { 'Cache-Control': `max-age=${ttl}` } }));
  } catch { /* 無視 */ }
}

async function requestToken(env, body) {
  const res = await fetch(TOKEN_URL, {
    method: 'POST',
    headers: {
      'Accept': 'application/json; charset=utf-8',
      'Content-Type': 'application/x-www-form-urlencoded',
      'Authorization': `Basic ${btoa(`${env.SC_CLIENT_ID}:${env.SC_CLIENT_SECRET}`)}`,
    },
    body,
  });
  if (res.status === 429) {
    // 原因を調べるための記録（SoundCloudが返した制限の情報）
    try {
      const info = { at: new Date().toISOString(), headers: Object.fromEntries([...res.headers].filter(([k]) => /rate|retry|limit|reset|cf-|date/i.test(k))), body: (await res.clone().text()).slice(0, 400) };
      await caches.default.put('https://onpa-cache.internal/sc-last-429', new Response(JSON.stringify(info), { headers: { 'Cache-Control': 'max-age=86400' } }));
    } catch { /* 無視 */ }
    // SoundCloudが「いつ解除か」を教えてくれれば、それまで待つ。なければ10分
    const ra = Number(res.headers.get('Retry-After'));
    const reset = Number(res.headers.get('X-Ratelimit-Reset'));
    const until = reset > 1e9 ? reset * 1000 : ra > 0 ? Date.now() + ra * 1000 : Date.now() + 10 * 60 * 1000;
    await writeBlocked(Math.min(until, Date.now() + 12 * 3600 * 1000));
    const e = new Error('SoundCloudが混み合っています（回数制限）');
    e.status = 503;
    throw e;
  }
  if (!res.ok) throw new Error(`token取得に失敗: ${res.status}`);
  const data = await res.json();
  return { token: data.access_token, rt: data.refresh_token || null, exp: Date.now() + Math.max((data.expires_in || 3600) - 120, 60) * 1000 };
}

async function getToken(env) {
  if (cached.token && Date.now() < cached.exp) return cached.token;
  const fromCache = await readCachedToken();
  if (fromCache) { cached = fromCache; return cached.token; }
  const until = await readBlocked();
  if (until) {
    const e = new Error(`SoundCloudが混み合っています（回数制限・${new Date(until).toISOString()}ごろ解除）`);
    e.status = 503;
    throw e;
  }
  let d = null;
  // 期限切れなら、新しく発行してもらう代わりに「更新」を試す（回数制限にかかりにくい）
  if (cached.rt) {
    try { d = await requestToken(env, `grant_type=refresh_token&refresh_token=${encodeURIComponent(cached.rt)}`); } catch { d = null; }
  }
  if (!d) d = await requestToken(env, 'grant_type=client_credentials');
  cached = d;
  await writeCachedToken(d);
  return d.token;
}

// SoundCloudに連携している人は、その人の合鍵で呼ぶ（アプリの入場券の回数制限に左右されない）
async function scGet(path, env, userToken = '') {
  if (userToken) {
    const r = await fetch(`${API}${path}`, {
      headers: { 'Accept': 'application/json; charset=utf-8', 'Authorization': `OAuth ${userToken}` },
    });
    if (r.ok) return r.json();
    if (r.status !== 401 && r.status !== 403) { const e = new Error(`SoundCloud ${r.status}`); e.status = r.status === 429 ? 503 : 502; throw e; }
  }
  const token = await getToken(env);
  const res = await fetch(`${API}${path}`, {
    headers: { 'Accept': 'application/json; charset=utf-8', 'Authorization': `OAuth ${token}` },
  });
  if (!res.ok) throw new Error(`SoundCloud API ${res.status}`);
  return res.json();
}

// ユーザー本人の合鍵でSoundCloudを呼ぶ
async function scUser(path, userToken, method = 'GET') {
  const res = await fetch(`${API}${path}`, {
    method,
    headers: { 'Accept': 'application/json; charset=utf-8', 'Authorization': `OAuth ${userToken}` },
  });
  const text = await res.text();
  let body = null;
  try { body = text ? JSON.parse(text) : null; } catch { body = text; }
  return { ok: res.ok, status: res.status, body };
}

const playCache = new Map();

async function candidates(id, env, userToken = '') {
  const s = await scGet(`/tracks/${id}/streams`, env, userToken);
  return [
    { kind: 'full', hls: true, apiUrl: s.hls_aac_160_url },
    { kind: 'full', hls: true, apiUrl: s.hls_mp3_128_url },
    { kind: 'full', hls: false, apiUrl: s.http_mp3_128_url },
    { kind: 'preview', hls: false, apiUrl: s.preview_mp3_128_url },
  ].filter((c) => c.apiUrl);
}

// ===================== Onpaのログイン確認（Firebase） =====================
const FIREBASE_PROJECT = 'onpa-e7cc6';
const FIREBASE_DB = 'https://onpa-e7cc6-default-rtdb.asia-southeast1.firebasedatabase.app';
const GOOGLE_JWKS = 'https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com';
let jwksCache = { keys: null, exp: 0 };

function b64urlToBytes(s) {
  const b = atob(s.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((s.length + 3) % 4));
  return Uint8Array.from(b, (c) => c.charCodeAt(0));
}

// アプリから届いた「Onpaのログイン証明（IDトークン）」が本物か確かめて、ユーザーIDを返す
async function verifyFirebaseIdToken(idToken) {
  const parts = (idToken || '').split('.');
  if (parts.length !== 3) throw new Error('ログインが必要です');
  const header = JSON.parse(new TextDecoder().decode(b64urlToBytes(parts[0])));
  const payload = JSON.parse(new TextDecoder().decode(b64urlToBytes(parts[1])));
  const now = Math.floor(Date.now() / 1000);
  if (header.alg !== 'RS256') throw new Error('不正なトークンです');
  if (payload.aud !== FIREBASE_PROJECT || payload.iss !== `https://securetoken.google.com/${FIREBASE_PROJECT}`) throw new Error('不正なトークンです');
  if (!payload.sub || payload.exp < now || payload.iat > now + 300) throw new Error('ログインの期限が切れています');

  if (!jwksCache.keys || jwksCache.exp < Date.now()) {
    const r = await fetch(GOOGLE_JWKS);
    const d = await r.json();
    jwksCache = { keys: d.keys, exp: Date.now() + 60 * 60 * 1000 };
  }
  const jwk = jwksCache.keys.find((k) => k.kid === header.kid);
  if (!jwk) throw new Error('不正なトークンです');
  const key = await crypto.subtle.importKey('jwk', jwk, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['verify']);
  const ok = await crypto.subtle.verify('RSASSA-PKCS1-v1_5', key, b64urlToBytes(parts[2]), new TextEncoder().encode(`${parts[0]}.${parts[1]}`));
  if (!ok) throw new Error('不正なトークンです');
  return payload.sub;
}

// その人が、その通話の当事者（かけた人 or かけられた人）か確かめる
async function isCallMember(room, uid, idToken) {
  const r = await fetch(`${FIREBASE_DB}/rooms/${encodeURIComponent(room)}/call.json?auth=${encodeURIComponent(idToken)}`);
  if (!r.ok) return false;
  const c = await r.json();
  return !!c && (c.from === uid || c.to === uid);
}

// ===================== LiveKit（通話）の入場券 =====================
async function livekitToken(env, room, identity, name) {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: 'HS256', typ: 'JWT' };
  const payload = {
    iss: env.LK_API_KEY,
    sub: identity,
    name,
    nbf: now - 10,
    exp: now + 6 * 60 * 60,
    video: { room, roomJoin: true, canPublish: true, canSubscribe: true, canPublishData: true },
  };
  const data = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(payload))}`;
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(env.LK_API_SECRET), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(data));
  return `${data}.${b64url(sig)}`;
}

// ===================== SoundCloudでログイン =====================
function redirectUri(url) { return `${url.origin}/sc/callback`; }

async function scLogin(url, env) {
  const ret = url.searchParams.get('return') || '';
  if (!isAllowedReturn(ret)) return new Response('return が不正です', { status: 400 });
  const verifier = randomString(64);
  const challenge = b64url(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier)));
  const state = randomString(24);
  const auth = new URL(AUTH_URL);
  auth.searchParams.set('client_id', env.SC_CLIENT_ID);
  auth.searchParams.set('redirect_uri', redirectUri(url));
  auth.searchParams.set('response_type', 'code');
  auth.searchParams.set('code_challenge', challenge);
  auth.searchParams.set('code_challenge_method', 'S256');
  auth.searchParams.set('state', state);
  const cookie = b64url(JSON.stringify({ v: verifier, s: state, r: ret }));
  return new Response(null, {
    status: 302,
    headers: {
      'Location': auth.toString(),
      'Set-Cookie': `sc_login=${cookie}; Path=/sc; Max-Age=600; HttpOnly; Secure; SameSite=Lax`,
    },
  });
}

function readCookie(request, name) {
  const c = request.headers.get('Cookie') || '';
  const m = c.match(new RegExp(`(?:^|;\\s*)${name}=([^;]+)`));
  return m ? m[1] : null;
}

async function scCallback(request, url, env) {
  const raw = readCookie(request, 'sc_login');
  let saved = null;
  try { saved = JSON.parse(atob(raw.replace(/-/g, '+').replace(/_/g, '/'))); } catch { /* 下で弾く */ }
  if (!saved || saved.s !== url.searchParams.get('state')) return new Response('ログインの確認に失敗しました。もう一度やり直してください。', { status: 400 });

  const back = (hash) => new Response(null, {
    status: 302,
    headers: { 'Location': `${saved.r}#${hash}`, 'Set-Cookie': 'sc_login=; Path=/sc; Max-Age=0; HttpOnly; Secure; SameSite=Lax' },
  });

  const code = url.searchParams.get('code');
  if (!code) return back('sc_error=' + encodeURIComponent(url.searchParams.get('error') || 'cancelled'));

  const res = await fetch(TOKEN_URL, {
    method: 'POST',
    headers: { 'Accept': 'application/json; charset=utf-8', 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'authorization_code',
      client_id: env.SC_CLIENT_ID,
      client_secret: env.SC_CLIENT_SECRET,
      redirect_uri: redirectUri(url),
      code_verifier: saved.v,
      code,
    }),
  });
  if (!res.ok) return back('sc_error=' + encodeURIComponent('token ' + res.status));
  const t = await res.json();
  const payload = { at: t.access_token, rt: t.refresh_token, exp: Date.now() + (t.expires_in || 3600) * 1000 };
  return back('sc=' + b64url(JSON.stringify(payload)));
}

async function scRefresh(request, env, cors) {
  const { rt } = await request.json().catch(() => ({}));
  if (!rt) return json({ error: 'rt が必要です' }, 400, cors);
  const res = await fetch(TOKEN_URL, {
    method: 'POST',
    headers: { 'Accept': 'application/json; charset=utf-8', 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'refresh_token', client_id: env.SC_CLIENT_ID, client_secret: env.SC_CLIENT_SECRET, refresh_token: rt }),
  });
  if (!res.ok) return json({ error: 'refresh ' + res.status }, res.status === 400 || res.status === 401 ? 401 : 503, cors);
  const t = await res.json();
  return json({ at: t.access_token, rt: t.refresh_token || rt, exp: Date.now() + (t.expires_in || 3600) * 1000 }, 200, cors);
}

// ===================== 入り口 =====================
export default {
  async fetch(request, env) {
    const cors = corsHeaders(request);
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
    const url = new URL(request.url);
    const p = url.pathname;
    const userToken = request.headers.get('X-SC-Token') || '';

    try {
      // ---- 検索: /search?q=曲名
      if (p === '/search') {
        const q = (url.searchParams.get('q') || '').trim();
        if (!q) return json({ error: 'q が必要です' }, 400, cors);
        const d = await scGet(`/tracks?q=${encodeURIComponent(q)}&limit=20&access=playable`, env, userToken);
        return json(listOf(d).map(mapTrack), 200, cors);
      }

      // ---- 調査用: 最後に断られたときの記録を見る
      if (p === '/debug/last429') {
        const hit = await caches.default.match('https://onpa-cache.internal/sc-last-429');
        return json(hit ? await hit.json() : { none: true, blockedUntil: await readBlocked() }, 200, cors);
      }

      // ---- 調査用: 制限中でも1回だけ発行を試す（券そのものは返さない）
      if (p === '/debug/try') {
        const res = await fetch(TOKEN_URL, {
          method: 'POST',
          headers: { 'Accept': 'application/json; charset=utf-8', 'Content-Type': 'application/x-www-form-urlencoded', 'Authorization': `Basic ${btoa(`${env.SC_CLIENT_ID}:${env.SC_CLIENT_SECRET}`)}` },
          body: 'grant_type=client_credentials',
        });
        const text = await res.text();
        let ok = false;
        if (res.ok) {
          try {
            const data = JSON.parse(text);
            const d = { token: data.access_token, rt: data.refresh_token || null, exp: Date.now() + Math.max((data.expires_in || 3600) - 120, 60) * 1000 };
            cached = d; await writeCachedToken(d); await writeBlocked(0); ok = true;
          } catch { /* 無視 */ }
        }
        return json({ status: res.status, ok, headers: Object.fromEntries([...res.headers]), body: ok ? '(token saved)' : text.slice(0, 400) }, 200, cors);
      }

      // ---- 再生: /play?id=曲ID → 鳴らせるURL（フル優先、だめなら30秒）
      if (p === '/play') {
        const id = url.searchParams.get('id') || '';
        if (!/^\d+$/.test(id)) return json({ error: 'id が不正です' }, 400, cors);
        const hit = playCache.get(id);
        if (hit && hit.exp > Date.now()) return json(hit.body, 200, cors);
        const cands = await candidates(id, env, userToken);
        const token = userToken || await getToken(env);
        const tried = [];
        for (const c of cands) {
          const r = await fetch(c.apiUrl, { headers: { 'Authorization': `OAuth ${token}` }, redirect: 'manual' });
          const loc = r.headers.get('Location');
          tried.push({ kind: c.kind, status: r.status });
          if (loc) {
            const body = { kind: c.kind, hls: c.hls, url: loc };
            playCache.set(id, { body, exp: Date.now() + 10 * 60 * 1000 });
            return json(body, 200, cors);
          }
        }
        return json({ error: 'この曲は再生できません', tried }, 404, cors);
      }

      // ---- 関連する曲: /related?id=曲ID （曲が終わったら続けて流す用）
      if (p === '/related') {
        const id = url.searchParams.get('id') || '';
        if (!/^\d+$/.test(id)) return json({ error: 'id が不正です' }, 400, cors);
        const d = await scGet(`/tracks/${id}/related?limit=20&access=playable`, env, userToken);
        return json(listOf(d).map(mapTrack), 200, cors);
      }

      // ---- 通話の入場券: /livekit-token?room=&identity=&name=
      if (p === '/livekit-token') {
        if (!env.LK_API_KEY || !env.LK_API_SECRET) return json({ error: 'LiveKitの鍵が未設定です' }, 500, cors);
        const room = (url.searchParams.get('room') || '').slice(0, 64);
        const name = (url.searchParams.get('name') || '').slice(0, 40);
        if (!/^[\w-]+$/.test(room)) return json({ error: 'room は英数字・_・- だけ使えます' }, 400, cors);
        // Onpaにログインしていて、この通話の当事者である人だけに発行する
        const idToken = (request.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
        let uid;
        try { uid = await verifyFirebaseIdToken(idToken); } catch (e) { return json({ error: e.message }, 401, cors); }
        if (!(await isCallMember(room, uid, idToken))) return json({ error: 'この通話に参加できません' }, 403, cors);
        return json({ token: await livekitToken(env, room, uid, name || uid) }, 200, cors);
      }

      // ---- SoundCloudでログイン
      if (p === '/sc/login') return scLogin(url, env);
      if (p === '/sc/callback') return scCallback(request, url, env);
      if (p === '/sc/refresh' && request.method === 'POST') return scRefresh(request, env, cors);

      // ---- SoundCloudのアカウントで Otocloud に入る: /auth/sc
      // SoundCloudの合鍵を確かめて、そのSoundCloudアカウント専用のログイン情報を返す。
      // 同じSoundCloudなら、どの端末でも同じ Otocloud アカウントになる。
      if (p === '/auth/sc') {
        if (!userToken) return json({ error: 'SoundCloudにログインしていません' }, 401, cors);
        if (!env.AUTH_SECRET) return json({ error: 'AUTH_SECRET が未設定です' }, 500, cors);
        const r = await scUser('/me', userToken);
        if (!r.ok || !r.body || !r.body.id) return json({ error: 'SoundCloudの確認に失敗しました' }, 401, cors);
        const id = String(r.body.id);
        const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(env.AUTH_SECRET), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
        const sig = new Uint8Array(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode('sc:' + id)));
        const password = btoa(String.fromCharCode(...sig)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
        const res = json({ email: `sc-${id}@users.on-pa.net`, password, scId: id, username: r.body.username || '', permalink: r.body.permalink || '', fullName: r.body.full_name || '', avatar: r.body.avatar_url || '' }, 200, cors);
        res.headers.set('Cache-Control', 'no-store');
        return res;
      }

      // ---- ここから先は、ログインした本人の合鍵が必要
      if (p.startsWith('/sc/')) {
        if (!userToken) return json({ error: 'SoundCloudにログインしていません' }, 401, cors);

        // 自分の情報
        if (p === '/sc/me') {
          const r = await scUser('/me', userToken);
          if (!r.ok) return json({ error: 'me ' + r.status }, r.status, cors);
          const u = r.body;
          return json({ id: u.id, username: u.username, avatar: u.avatar_url, permalink: u.permalink_url }, 200, cors);
        }

        // 自分のいいね一覧
        if (p === '/sc/likes') {
          const r = await scUser('/me/likes/tracks?limit=200&linked_partitioning=true&access=playable', userToken);
          if (!r.ok) return json({ error: 'likes ' + r.status }, r.status, cors);
          return json(listOf(r.body).map(mapTrack), 200, cors);
        }

        // 自分がアップロードした曲
        if (p === '/sc/tracks') {
          const r = await scUser('/me/tracks?limit=50&linked_partitioning=true', userToken);
          if (!r.ok) return json({ error: 'tracks ' + r.status }, r.status, cors);
          return json(listOf(r.body).map(mapTrack), 200, cors);
        }

        // 自分のプレイリスト一覧
        if (p === '/sc/playlists') {
          const r = await scUser('/me/playlists?limit=50&show_tracks=false&linked_partitioning=true', userToken);
          if (!r.ok) return json({ error: 'playlists ' + r.status }, r.status, cors);
          return json(listOf(r.body).map((pl) => ({ id: pl.id, title: pl.title, count: pl.track_count, artwork: pl.artwork_url || '' })), 200, cors);
        }

        // プレイリストの中の曲: /sc/playlist?id=
        if (p === '/sc/playlist') {
          const id = url.searchParams.get('id') || '';
          if (!/^\d+$/.test(id)) return json({ error: 'id が不正です' }, 400, cors);
          const r = await scUser(`/playlists/${id}/tracks?limit=200&linked_partitioning=true&access=playable`, userToken);
          if (!r.ok) return json({ error: 'playlist ' + r.status }, r.status, cors);
          return json(listOf(r.body).map(mapTrack), 200, cors);
        }

        // いいねする（POST）／外す（DELETE）: /sc/like?id=
        if (p === '/sc/like') {
          const id = url.searchParams.get('id') || '';
          if (!/^\d+$/.test(id)) return json({ error: 'id が不正です' }, 400, cors);
          if (request.method !== 'POST' && request.method !== 'DELETE') return json({ error: 'POST か DELETE で呼んでください' }, 405, cors);
          const r = await scUser(`/likes/tracks/${id}`, userToken, request.method);
          if (!r.ok) return json({ error: 'like ' + r.status, detail: r.body }, r.status, cors);
          return json({ ok: true, liked: request.method === 'POST' }, 200, cors);
        }
      }

      return json({ ok: true, routes: ['/search', '/play', '/related', '/livekit-token', '/sc/login', '/sc/me', '/sc/likes', '/sc/playlists', '/sc/playlist', '/sc/like'] }, 200, cors);
    } catch (e) {
      return json({ error: e.message }, e.status || 500, cors);
    }
  },
};
