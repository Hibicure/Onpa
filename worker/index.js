// Cloudflare Worker - Otocloud 中継役（SoundCloud 公式API ＋ LiveKit 入場券）
// 秘密の値はここに書かず、Cloudflareの「Variables and Secrets」に入れる：
//   SC_CLIENT_ID / SC_CLIENT_SECRET … SoundCloudアプリの鍵
//   LK_API_KEY / LK_API_SECRET     … LiveKitの鍵

const TOKEN_URL = 'https://secure.soundcloud.com/oauth/token';
const AUTH_URL = 'https://secure.soundcloud.com/authorize';
const API = 'https://api.soundcloud.com';

// 使えるサイト（これ以外から呼ばれても許可しない）
const ALLOWED_ORIGINS = [
  'https://on-pa.net',
  'https://otocloud.app',
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
// プレイリストのジャケット：無い時は、SoundCloud と同じく中の最初の曲のジャケットを使う
function plArt(pl) {
  if (pl.artwork_url) return pl.artwork_url;
  const t = (pl.tracks || []).find((x) => x && x.artwork_url);
  return t ? t.artwork_url : '';
}

function mapTrack(t) {
  return {
    id: t.id,
    title: t.title,
    artist: t.metadata_artist || t.publisher_metadata?.artist || t.user?.username || 'Unknown',
    uploader: t.user?.username || '',
    userId: t.user?.id || null,
    artwork: t.artwork_url || t.user?.avatar_url || '',
    duration: t.duration,
    access: t.access,
    permalink_url: t.permalink_url,
    waveform: t.waveform_url || '',
    plays: t.playback_count || 0, // 検索の並び替えに使う（よく聴かれている曲を上に）
    isrc: String(t.publisher_metadata?.isrc || '').toUpperCase().replace(/[^A-Z0-9]/g, ''), // 世界共通の曲番号（配信している曲には付いていることが多い）
    // 非公開曲の秘密の鍵（secret_token が無い時は secret_uri の中から取り出す）
    secret: t.sharing === 'private' ? (t.secret_token || (String(t.secret_uri || '').match(/secret_token=([A-Za-z0-9-]+)/) || [])[1] || '') : '',
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
// MusicBrainz（だれでも使える音楽のデータベース）で、アーティストの出身地（なければ活動している国）を調べる。
// Spotify のアーティストは、MusicBrainz に登録されたリンクで確実に同じ人を探す。なければ名前が完全に同じ人だけ
const MB_H = { 'User-Agent': 'Otocloud/1.0 ( support@otocloud.app )', 'Accept': 'application/json' };
const nap = (ms) => new Promise((ok) => setTimeout(ok, ms));
async function mbArea(a) {
  try {
    let id = '';
    if (a.sp) {
      const r = await fetch('https://musicbrainz.org/ws/2/url?inc=artist-rels&fmt=json&resource=' + encodeURIComponent('https://open.spotify.com/artist/' + a.sp), { headers: MB_H });
      if (r.status === 503) return null;
      if (r.ok) { const d = await r.json(); const rel = (d.relations || []).find((x) => x.artist); if (rel) id = rel.artist.id; }
      await nap(1100);
    }
    if (!id) {
      const name = String(a.name || '').trim();
      const r = await fetch('https://musicbrainz.org/ws/2/artist?fmt=json&limit=5&query=' + encodeURIComponent('artist:"' + name.replace(/"/g, '') + '"'), { headers: MB_H });
      if (r.status === 503) return null;
      if (r.ok) { const d = await r.json(); const best = (d.artists || []).find((x) => x.score >= 95 && String(x.name).toLowerCase() === name.toLowerCase()); if (best) id = best.id; }
      await nap(1100);
    }
    if (!id) return { city: '', country: '' };
    const r = await fetch(`https://musicbrainz.org/ws/2/artist/${id}?fmt=json`, { headers: MB_H });
    if (r.status === 503) return null;
    if (!r.ok) return { city: '', country: '' };
    const d = await r.json();
    const ba = d['begin-area'], ar = d.area;
    const city = ba && ba.type !== 'Country' ? ba.name : ar && ar.type !== 'Country' ? ar.name : '';
    let country = ar && ar.type === 'Country' ? ar.name : '';
    if (!country && d.country) { try { country = new Intl.DisplayNames(['en'], { type: 'region' }).of(d.country) || d.country; } catch { country = d.country; } }
    return { city, country };
  } catch { return null; }
}

// 街の名前（と国）から緯度・経度を出す（Open-Meteo の無料の地名検索）。30日覚えておく
async function geocode(city, country, allowFetch = true) {
  const name = city || country;
  if (!name) return null;
  const ck = new Request('https://cache.otocloud/geo/' + encodeURIComponent((city + '|' + country).toLowerCase()));
  const hit = await caches.default.match(ck);
  if (hit) return hit.json();
  if (!allowFetch) return null;
  let g = { lat: null };
  try {
    const r = await fetch('https://geocoding-api.open-meteo.com/v1/search?count=10&language=en&format=json&name=' + encodeURIComponent(name));
    const d = await r.json();
    const res = (d && d.results) || [];
    const c = country.toLowerCase();
    const same = (x) => String(x.country || '').toLowerCase() === c || String(x.country_code || '').toLowerCase() === c;
    const pick = !city ? (res.find((x) => /^PCL/.test(x.feature_code || '') && same(x)) || res.find((x) => /^PCL/.test(x.feature_code || '')))
      : (c && res.find(same)) || (c ? null : res[0]);
    if (pick) g = { lat: Math.round(pick.latitude * 100) / 100, lng: Math.round(pick.longitude * 100) / 100, name: [...new Set([pick.name, pick.country].filter(Boolean))].join(', ') };
  } catch {}
  await caches.default.put(ck, new Response(JSON.stringify(g), { headers: { 'Content-Type': 'application/json', 'Cache-Control': 'public, max-age=2592000' } }));
  return { ...g, fresh: true };
}

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

// 曲ごとの「音の出どころの一覧」は変わらないので1日覚えておく（SoundCloudへの再生の問い合わせを、1曲1回に減らす）
async function candidates(id, env, userToken = '') {
  const ck = new Request('https://cache.otocloud/cands/' + id);
  const hit = await caches.default.match(ck);
  if (hit) return hit.json();
  const list = await candidatesFresh(id, env, userToken);
  if (list.length) await caches.default.put(ck, new Response(JSON.stringify(list), { headers: { 'Cache-Control': 'public, max-age=86400' } }));
  return list;
}
async function candidatesFresh(id, env, userToken = '') {
  const s = await scGet(`/tracks/${id}/streams`, env, userToken);
  return [
    { kind: 'full', hls: true, apiUrl: s.hls_aac_160_url },
    { kind: 'full', hls: true, apiUrl: s.hls_mp3_128_url },
    { kind: 'full', hls: false, apiUrl: s.http_mp3_128_url },
    { kind: 'preview', hls: false, apiUrl: s.preview_mp3_128_url },
  ].filter((c) => c.apiUrl);
}

// ===================== Otocloudのログイン確認（Firebase） =====================
const FIREBASE_PROJECT = 'onpa-e7cc6';
const FIREBASE_DB = 'https://onpa-e7cc6-default-rtdb.asia-southeast1.firebasedatabase.app';
const GOOGLE_JWKS = 'https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com';
let jwksCache = { keys: null, exp: 0 };

function b64urlToBytes(s) {
  const b = atob(s.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((s.length + 3) % 4));
  return Uint8Array.from(b, (c) => c.charCodeAt(0));
}

// アプリから届いた「Otocloudのログイン証明（IDトークン）」が本物か確かめて、ユーザーIDを返す
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


// ===================== 共有 =====================
// 曲の情報は1日キャッシュする（入場券の回数を使いすぎないように）
async function trackInfo(id, env, userToken = '', st = '') {
  if (st && !/^s-[A-Za-z0-9]{1,40}$/.test(st)) st = '';
  const cache = caches.default;
  const key = new Request('https://cache.otocloud/track2/' + id + (st ? '/' + st : ''));
  const hit = await cache.match(key);
  if (hit) return hit.json();
  try {
    const t = mapTrack(await scGet('/tracks/' + id + (st ? '?secret_token=' + st : ''), env, userToken));
    if (st) t.secret = st;
    if (t.artwork) t.artwork = t.artwork.replace('-large.', '-t500x500.');
    // 持ち主の鍵で取った非公開曲の鍵は、他の人に配らない（キャッシュしない）
    if (t.secret && !st) return t;
    await cache.put(key, new Response(JSON.stringify(t), { headers: { 'Cache-Control': 'public, max-age=86400', 'Content-Type': 'application/json' } }));
    return t;
  } catch { return null; }
}

// ===================== 歌詞（曲の説明欄・本人のコメントから探す） =====================
// 日本のアーティストは説明欄に歌詞を載せていることが多い。クレジットやリンクの行は外して、
// 「短い行が何行も続くかたまり」を歌詞とみなす
const CREDIT = /(https?:|www\.|@|\bprod\b|produced|\bmix(ed)?\b|master(ed|ing)?|illust|artwork|\bart\b|\bmv\b|movie|video|instagram|twitter|tiktok|youtube|spotify|apple ?music|bandcamp|lyrics? by|music by|words by|vocal|作詞|作曲|編曲|イラスト|動画|映像|ミックス|マスタリング|リリース|配信|follow|#|^\d{1,2}\s*[.)]\s|\bfeat\.|\bft\.|^[词曲编][：:]|^(词|曲|编曲|制作人|混音)\s*[：:])/i;
function findLyrics(text) {
  const lines = String(text || '').replace(/\r/g, '').split('\n');
  // 「歌詞」「Lyrics」の見出しがあれば、その下から
  let start = lines.findIndex((l) => /^\s*[\[【(（]?\s*(歌詞|lyrics?)\s*[\]】)）]?\s*[:：]?\s*$/i.test(l));
  const body = start >= 0 ? lines.slice(start + 1) : lines;
  let best = [], cur = [], blanks = 0;
  const flush = () => { while (cur.length && !cur[cur.length - 1].trim()) cur.pop(); if (cur.filter((l) => l.trim()).length > best.filter((l) => l.trim()).length) best = cur; cur = []; blanks = 0; };
  for (const raw of body) {
    const l = raw.trim();
    if (!l) { if (cur.length) { blanks++; if (blanks > 2) flush(); else cur.push(''); } continue; }
    if (l.length > 70 || CREDIT.test(l)) { flush(); continue; }
    blanks = 0; cur.push(l);
  }
  flush();
  const n = best.filter((l) => l.trim()).length;
  return n >= (start >= 0 ? 3 : 6) ? best.join('\n') : '';
}
// 曲名を検索しやすい形に（[MV] (prod. x) feat. y などを外す）
function cleanTitle(s) {
  return String(s || '')
    .replace(/[\[【(（「][^\]】)）」]*(prod|feat|ft\.|mv|m\/v|official|video|lyric|audio|free|dl|download|out now|release|full|ver\.?|version|remaster|cover|カバー|歌ってみた|オリジナル|original)[^\]】)）」]*[\]】)）」]/gi, '')
    .replace(/\s(feat|ft)\.?\s.+$/i, '')
    .replace(/[\[【][^\]】]*[\]】]/g, '')
    .replace(/\s+/g, ' ').trim();
}
function normName(s) { return String(s || '').toLowerCase().normalize('NFKC').replace(/[\s'’"“”・.,!?！？~〜\-–—_/]/g, ''); }
// LRCLIB（だれでも使える歌詞のデータベース。時間つき歌詞もある）で、曲名とアーティスト名から探す
async function lrclib(t, trace = []) {
  const UA = { 'User-Agent': 'Otocloud (https://otocloud.app)' };
  const raw = String(t.publisher_metadata?.release_title || t.title || '');
  // リミックス・カバー・速さ違いは、長さが違っても歌詞は同じ
  const loose = /remix|edit|cover|sped|slowed|nightcore|bootleg|flip|rework|カバー|歌ってみた|弾き語り|acoustic|live/i.test(raw);
  let title = cleanTitle(raw);
  let artist = String(t.publisher_metadata?.artist || t.user?.username || '').trim();
  const pairs = [[title, artist]];
  const dash = title.match(/^(.+?)\s+[-–—]\s+(.+)$/);
  if (dash) { pairs.unshift([cleanTitle(dash[2]), dash[1].trim()]); pairs.splice(1, 0, [cleanTitle(dash[1]), dash[2].trim()]); }
  const dur = Math.round((t.full_duration || t.duration || 0) / 1000);
  const tidy = (txt) => String(txt || '').split('\n').filter((l) => !/^\s*(作[词詞]|作曲|[编編]曲|制作人|混音|和声|Lời|Lyrics by|Composed by)\s*.{0,40}[:：]/i.test(l)).join('\n').replace(/^\s+/, '');
  const pick = (x) => x && !x.instrumental && (x.plainLyrics || x.syncedLyrics) ? { lyrics: tidy(x.plainLyrics || x.syncedLyrics.replace(/^\[[^\]]*\]\s?/gm, '')), synced: loose ? '' : (x.syncedLyrics || ''), from: 'lrclib' } : null;
  // ① 曲名・アーティスト名・長さがぴったり
  if (!loose) for (const [ti, ar] of pairs) {
    try {
      const q = new URLSearchParams({ track_name: ti, artist_name: ar }); if (dur) q.set('duration', String(dur));
      const r = await fetch('https://lrclib.net/api/get?' + q, { headers: UA });
      trace.push('get ' + r.status + ' ' + ti + ' / ' + ar + ' ' + dur);
      if (r.ok) { const hit = pick(await r.json()); if (hit) return hit; }
    } catch { /* つぎへ */ }
  }
  // ② 検索して、曲名とアーティスト名が合うもの（長さが近い順）
  const tn = (x) => normName(x.trackName), an = (x) => normName(x.artistName);
  // 似ている：同じか、片方がもう片方を含んでいて長さもほぼ同じ（「Home」と「Home Alone」は別の曲）
  const near = (a, b) => a === b || (a.length >= 2 && b.length >= 2 && (a.includes(b) || b.includes(a)) && Math.min(a.length, b.length) / Math.max(a.length, b.length) >= 0.7);
  const seen = new Set();
  for (const q of [`${artist} ${title}`, ...pairs.map((p) => p[0])]) {
    if (seen.has(q)) continue; seen.add(q);
    try {
      const r = await fetch('https://lrclib.net/api/search?' + new URLSearchParams({ q }), { headers: UA });
      trace.push('search ' + r.status + ' ' + q);
      if (!r.ok) continue;
      const list = ((await r.json()) || []).filter((x) => !/inst|instrumental|off ?vocal|karaoke|カラオケ|オフボーカル/i.test(x.trackName || ''));
      for (const [ti, ar] of pairs) {
        const nt = normName(ti), na = normName(ar);
        if (nt.length < 2) continue;
        const ok = list.filter((x) => near(tn(x), nt))
          .filter((x) => !na || near(an(x), na) || an(x).includes(na) || na.includes(an(x)) || tn(x).includes(na)) // アーティストが違う曲は使わない
          .sort((p, q) => Math.abs((p.duration || 0) - dur) - Math.abs((q.duration || 0) - dur));
        for (const x of ok) { if (!loose && dur && x.duration && Math.abs(x.duration - dur) > 12) continue; const hit = pick(x); if (hit) return hit; }
      }
    } catch { /* つぎへ */ }
  }
  return null;
}
async function lyricsOf(id, env, userToken, st, dbg) {
  const cache = caches.default;
  const key = new Request('https://cache.otocloud/lyrics5/' + id + (st ? '/' + st : ''));
  const hit = dbg ? null : await cache.match(key);
  if (hit) return hit.json();
  const trace = [];
  let out = { lyrics: '', from: '' };
  try {
    const t = await scGet('/tracks/' + id + (st ? '?secret_token=' + st : ''), env, userToken);
    const d = findLyrics(t.description);
    if (d) out = { lyrics: d, from: 'description' };
    else {
      // 説明欄に無ければ、コメント欄から（本人か、何行もあるコメント）
      const c = listOf(await scGet(`/tracks/${id}/comments?limit=200&linked_partitioning=true`, env, userToken));
      const owner = t.user?.id;
      // 曲名の「ft. ○○ & △△」に入っている人（客演）も、本人の次に優先する
      const featM = String(t.title || '').match(/\b(?:ft|feat)\.?\s*([^()\[\]【】]+)/i);
      const feats = featM ? featM[1].split(/\s*(?:&|,|、|\sx\s|\sand\s|×)\s*/i).map(normName).filter((n) => n.length >= 2) : [];
      const isFeat = (u) => { const a = normName(u?.username), b = normName(u?.permalink); return feats.some((f) => (a && (a.includes(f) || f.includes(a))) || (b && (b.includes(f) || f.includes(b)))); };
      const rank = (x) => (x.user?.id === owner ? 2 : isFeat(x.user) ? 1 : 0);
      const cands = c.filter((x) => String(x.body || '').split('\n').length >= 4).sort((a, b) => rank(b) - rank(a));
      for (const x of cands) {
        const l = findLyrics(x.body);
        if (!l) continue;
        // 同じ人が返信で続きを載せていたら、つなげる（「@名前」を外して、書いた順に）
        const t0 = Date.parse(x.created_at) || 0, who = x.user?.id;
        const more = c.filter((y) => y !== x && y.user?.id === who && (Date.parse(y.created_at) || 0) >= t0 && (Date.parse(y.created_at) || 0) - t0 < 3 * 864e5)
          .sort((p, q) => Date.parse(p.created_at) - Date.parse(q.created_at))
          .map((y) => String(y.body || '').replace(/^\s*@[^\s:：]+[:：]?\s*/, '').trim())
          .filter((b) => b.split('\n').filter((z) => z.trim()).length >= 2 && !/^(https?:|www\.)/i.test(b));
        out = { lyrics: [l, ...more].join('\n\n'), from: who === owner ? 'artist comment' : isFeat(x.user) ? 'featured artist comment' : 'comment', by: x.user?.username || '' };
        break;
      }
    }
    // SoundCloudに無ければ、曲名とアーティスト名で歌詞のデータベースを探す
    trace.push('sc ok: ' + (t.title || ''));
    if (!out.lyrics) { const l = await lrclib(t, trace); if (l) out = l; }
  } catch (e) { trace.push('err: ' + (e && e.message)); }
  if (dbg) return { ...out, trace };
  if (!out.lyrics || !st) await cache.put(key, new Response(JSON.stringify(out), { headers: { 'Cache-Control': 'public, max-age=' + (out.lyrics ? 86400 : 21600), 'Content-Type': 'application/json' } }));
  return out;
}
const escH = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
async function sharePage(id, env, st = '') {
  if (st && !/^s-[A-Za-z0-9]{1,40}$/.test(st)) st = '';
  const t = (await trackInfo(id, env, '', st)) || { id, title: 'A song on Otocloud', artist: '', artwork: '' };
  const app = 'https://otocloud.app/app/?t=' + id + (st ? '&st=' + st : '');
  const art = /^https:\/\/[a-z0-9.-]*sndcdn\.com\//.test(t.artwork || '') ? t.artwork : '';
  const title = t.artist ? `${t.title} — ${t.artist}` : t.title;
  const embed = 'https://w.soundcloud.com/player/?url=' + encodeURIComponent('https://api.soundcloud.com/tracks/' + id + (st ? '?secret_token=' + st : '')) + '&color=%23151517&auto_play=false&hide_related=true&show_comments=false&show_user=true&show_reposts=false&show_teaser=false&visual=false';
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>${escH(title)} · Otocloud</title>
<meta property="og:type" content="music.song"><meta property="og:site_name" content="Otocloud">
<meta property="og:title" content="${escH(title)}"><meta property="og:description" content="Listen together on Otocloud">
${art ? `<meta property="og:image" content="${escH(art)}"><meta name="twitter:image" content="${escH(art)}">` : ''}
<meta name="twitter:card" content="${art ? 'summary_large_image' : 'summary'}"><meta name="twitter:title" content="${escH(title)}">
<link rel="preconnect" href="https://fonts.googleapis.com"><link href="https://fonts.googleapis.com/css2?family=Unbounded:wght@600;700&family=Instrument+Sans:wght@500;600;700&display=swap" rel="stylesheet">
<style>
:root{--paper:#0e0f11;--ink:#f2f2f3;--mute:#9a9ca2}
*{box-sizing:border-box;margin:0;padding:0}
body{min-height:100dvh;background:var(--paper);color:var(--ink);font-family:'Instrument Sans',-apple-system,sans-serif;display:flex;flex-direction:column;align-items:center;padding:max(28px,env(safe-area-inset-top)) 22px max(28px,env(safe-area-inset-bottom));overflow-x:hidden}
.bg{position:fixed;inset:-20%;background:${art ? `url('${escH(art)}') center/cover` : '#222'};filter:blur(60px) saturate(1.3);opacity:.45;z-index:-1}
.brand{font:700 15px Unbounded,sans-serif;letter-spacing:-.01em;opacity:.9}
.disc{width:min(78vw,340px);aspect-ratio:1;border-radius:50%;margin:30px 0 26px;position:relative;box-shadow:0 30px 60px -24px rgba(0,0,0,.7),0 0 0 .5px rgba(255,255,255,.2);
 background:${art ? `url('${escH(art)}') center/cover` : 'radial-gradient(circle,#E9EBEE 0 33%,#C9CDD3 38%,#D3D6DB 70%,#B7BBC2 100%)'};animation:spin 9s linear infinite;animation-play-state:paused;
 -webkit-mask:radial-gradient(circle closest-side,transparent 0 11%,#000 11.5%);mask:radial-gradient(circle closest-side,transparent 0 11%,#000 11.5%)}
.disc.on{animation-play-state:running}
@keyframes spin{to{transform:rotate(360deg)}}
h1{font:700 clamp(22px,6.5vw,30px)/1.15 Unbounded,sans-serif;text-align:center;letter-spacing:-.02em;max-width:560px}
.artist{color:var(--mute);font-weight:600;margin-top:8px;text-align:center}
.player{width:100%;max-width:520px;margin-top:22px;border-radius:14px;overflow:hidden;height:120px}
.player iframe{width:100%;height:120px;border:0}
.open{margin-top:22px;display:inline-flex;align-items:center;justify-content:center;height:54px;padding:0 26px;border-radius:999px;background:var(--ink);color:#111;font-weight:700;font-size:16px;text-decoration:none}
.note{color:var(--mute);font-size:13px;margin-top:12px;text-align:center}
</style></head><body><div class="bg"></div>
<div class="brand">Otocloud</div>
<div class="disc" id="disc"></div>
<h1>${escH(t.title)}</h1>${t.artist ? `<div class="artist">${escH(t.artist)}</div>` : ''}
<div class="player"><iframe id="w" allow="autoplay" src="${embed}"></iframe></div>
<a class="open" href="${escH(app)}">Listen together in Otocloud</a>
<div class="note">Call a friend and hear this song at the same time.</div>
<script src="https://w.soundcloud.com/player/api.js"></script>
<script>try{const w=SC.Widget(document.getElementById('w')),d=document.getElementById('disc');w.bind(SC.Widget.Events.PLAY,()=>d.classList.add('on'));w.bind(SC.Widget.Events.PAUSE,()=>d.classList.remove('on'));w.bind(SC.Widget.Events.FINISH,()=>d.classList.remove('on'))}catch(e){}</script>
</body></html>`;
  return new Response(html, { status: 200, headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'public, max-age=3600' } });
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
        // 同じ言葉の検索は1時間みんなで使い回す（SoundCloudの検索の上限：アプリ全体で1時間3,000回）
        const sk = new Request('https://cache.otocloud/search/' + encodeURIComponent(q.toLowerCase().normalize('NFKC').replace(/\s+/g, ' ')));
        const sh = await caches.default.match(sk);
        if (sh) return json(await sh.json(), 200, cors);
        const d = await scGet(`/tracks?q=${encodeURIComponent(q)}&limit=20&access=playable`, env, userToken);
        const out = listOf(d).map(mapTrack);
        await caches.default.put(sk, new Response(JSON.stringify(out), { headers: { 'Cache-Control': 'public, max-age=3600' } }));
        return json(out, 200, cors);
      }

      // ---- 1曲の情報: /t/123（共有リンクから開いた時に使う）
      let m = p.match(/^\/t\/(\d{1,20})$/);
      if (m) {
        const t = await trackInfo(m[1], env, userToken, url.searchParams.get('st') || '');
        return t ? json(t, 200, cors) : json({ error: 'not found' }, 404, cors);
      }
      // ---- 歌詞: /lyrics/123
      m = p.match(/^\/lyrics\/(\d{1,20})$/);
      if (m) {
        let st = url.searchParams.get('st') || '';
        if (st && !/^s-[A-Za-z0-9]{1,40}$/.test(st)) st = '';
        return json(await lyricsOf(m[1], env, userToken, st, url.searchParams.get('debug') === '1'), 200, cors);
      }
      // ---- その人のプロフィール: /user/123（街・国など。アーティストページの上に出す）
      m = p.match(/^\/user\/(\d{1,20})$/);
      if (m) {
        const u = await scGet(`/users/${m[1]}`, env, userToken);
        const big = (x) => (x ? String(x).replace(/-(large|t\d+x\d+|crop|badge|small|tiny|mini)\./, '-t500x500.') : '');
        let banner = u.visuals?.visuals?.[0]?.visual_url || u.visual_url || u.banner_url || '';
        // ヘッダー画像（SoundCloudのプロフィールの上の横長の画像）。公式の仕組みには無いので、公開プロフィールのページに書いてあるものを読む
        const dbg = url.searchParams.get('debug') === '1', bt = [];
        if (!banner) {
          const cache = caches.default, bk = new Request('https://cache.otocloud/banner/' + m[1]);
          const hit = dbg ? null : await cache.match(bk);
          if (hit) banner = await hit.text();
          else {
            try {
              const tok = userToken || await getToken(env);
              const r2 = await fetch('https://api-v2.soundcloud.com/users/' + m[1], { headers: { 'Accept': 'application/json', 'Authorization': `OAuth ${tok}` } });
              bt.push('v2 ' + r2.status);
              if (r2.ok) { const v = await r2.json(); banner = v.visuals?.visuals?.[0]?.visual_url || ''; }
            } catch (e) { bt.push('v2 err ' + e.message); }
            if (!banner && u.permalink_url) {
              try {
                const r3 = await fetch(u.permalink_url, { headers: { 'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1', 'Accept-Language': 'en' } });
                bt.push('page ' + r3.status);
                if (r3.ok) { const h = await r3.text(); const mm = h.match(/"visual_url":"(https:[^"]+)"/) || h.match(/visual_url\\?":\\?"(https:[^"\\]+)/) || h.match(/(https:\/\/i1\.sndcdn\.com\/visuals-[^"'\s)\\]+)/); if (mm) banner = mm[1].replace(/\\u002F/g, '/'); bt.push('found ' + !!mm + ' len ' + h.length + ' vis ' + (h.indexOf('visuals') >= 0) + ' ' + (h.match(/.{0,80}visuals-.{0,80}/) || [''])[0]); }
              } catch (e) { bt.push('page err ' + e.message); }
            }
            await cache.put(bk, new Response(banner || '', { headers: { 'Cache-Control': 'public, max-age=' + (banner ? 86400 : 21600) } }));
          }
        }
        const out = { city: u.city || '', country: u.country || '', countryCode: u.country_code || '', followers: u.followers_count || 0,
          avatar: /default_avatar/.test(u.avatar_url || '') ? '' : big(u.avatar_url), banner: banner ? String(banner).replace(/-original\./, '-t2480x520.') : '', name: u.username || '', fullName: u.full_name || '', handle: u.permalink || '' };
        if (dbg) { out.keys = Object.keys(u); out.bt = bt; }
        return json(out, 200, cors);
      }
      // ---- その人の曲: /user/123/tracks（アーティスト名や友だちの名前から開くページ）
      m = p.match(/^\/user\/(\d{1,20})\/tracks$/);
      if (m) {
        // SoundCloudは1回に少ししか返さないので、続きのページもたどって全部集める（最大200曲）
        let d = await scGet(`/users/${m[1]}/tracks?limit=50&linked_partitioning=true&access=playable`, env, userToken);
        const all = listOf(d);
        for (let i = 0; i < 6 && d && d.next_href && all.length < 200; i++) {
          const next = String(d.next_href);
          if (!next.startsWith(API)) break;
          d = await scGet(next.slice(API.length), env, userToken);
          all.push(...listOf(d));
        }
        const seen = new Set();
        return json(all.filter((t) => t && !seen.has(t.id) && seen.add(t.id)).map(mapTrack), 200, cors);
      }
      // ---- Bandcamp の曲を名前で探す: /bc/search?q=…（Bandcamp のアプリが使っている検索の候補を借りる。公式に公開されたAPIではない）
      if (p === '/bc/search') {
        const q = (url.searchParams.get('q') || '').trim().slice(0, 100);
        if (!q) return json([], 200, cors);
        const key = new Request('https://cache.otocloud/bcs1/' + encodeURIComponent(q.toLowerCase()));
        const hit = await caches.default.match(key); if (hit) return new Response(hit.body, { headers: { ...cors, 'Content-Type': 'application/json' } });
        const r = await fetch('https://bandcamp.com/api/fuzzysearch/1/app_autocomplete?q=' + encodeURIComponent(q), { headers: { 'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1' } });
        if (!r.ok) return json({ error: 'bandcamp ' + r.status }, 502, cors);
        const d = await r.json().catch(() => ({}));
        const fixUrl = (u) => { u = String(u || ''); const i = u.lastIndexOf('https://'); return i > 0 ? u.slice(i) : u; };
        const out = (d.results || []).filter((x) => x && x.type === 't' && x.id).slice(0, 12).map((x) => ({
          id: 'bc:' + x.id, title: String(x.name || ''), artist: String(x.band_name || ''), uploader: String(x.band_name || ''),
          artwork: x.art_id ? `https://f4.bcbits.com/img/a${String(x.art_id).padStart(10, '0')}_10.jpg` : String(x.img || ''),
          album: String(x.album_name || ''), permalink_url: fixUrl(x.url), access: 'playable', provider: 'bandcamp', duration: 0,
        }));
        await caches.default.put(key, new Response(JSON.stringify(out), { headers: { 'Content-Type': 'application/json', 'Cache-Control': 'max-age=3600' } }));
        return json(out, 200, cors);
      }
      // ---- Bandcamp：アルバムか曲のページのURLから、曲の一覧（再生は公式の埋め込みプレーヤーで、端末の中で行う）
      //      /bc/album?url=https://xxx.bandcamp.com/album/yyy （または /track/zzz）
      if (p === '/bc/album') {
        let u; try { u = new URL(url.searchParams.get('url') || ''); } catch { return json({ error: 'bad url' }, 400, cors); }
        if (u.protocol !== 'https:' || !/^[a-z0-9-]+\.bandcamp\.com$/i.test(u.hostname) || !/^\/(album|track)\/[^/]+\/?$/.test(u.pathname)) return json({ error: 'Paste a bandcamp.com album or track link' }, 400, cors);
        const page = u.origin + u.pathname.replace(/\/$/, '');
        const key = new Request('https://cache.otocloud/bc2/' + encodeURIComponent(page));
        const hit = await caches.default.match(key); if (hit) return new Response(hit.body, { headers: { ...cors, 'Content-Type': 'application/json' } });
        const r = await fetch(page, { headers: { 'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1' } });
        if (!r.ok) return json({ error: 'bandcamp ' + r.status }, 502, cors);
        const html = await r.text();
        const m2 = html.match(/data-tralbum="([^"]*)"/);
        if (!m2) return json({ error: "Couldn't read this Bandcamp page" }, 502, cors);
        const dec = (x) => x.replace(/&quot;/g, '"').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&#39;/g, "'").replace(/&amp;/g, '&');
        let tr; try { tr = JSON.parse(dec(m2[1])); } catch { return json({ error: "Couldn't read this Bandcamp page" }, 502, cors); }
        const site = (html.match(/<meta property="og:site_name" content="([^"]*)"/) || [])[1] || '';
        const byLine = ((html.match(/<meta name="title" content="[^"]*?, by ([^"]*)"/) || [])[1]) || '';
        const artist = dec(String(tr.artist || byLine || site || ''));
        const art = tr.art_id ? `https://f4.bcbits.com/img/a${String(tr.art_id).padStart(10, '0')}_10.jpg` : '';
        const albumTitle = String((tr.current && tr.current.title) || '');
        const tracks = (tr.trackinfo || []).filter((t) => t && (t.track_id || t.id) && (t.file || t.streaming !== 0)).map((t) => ({
          id: 'bc:' + (t.track_id || t.id), title: String(t.title || ''), artist: String(t.artist || artist), artwork: art,
          duration: Math.round((Number(t.duration) || 0) * 1000), access: 'playable', provider: 'bandcamp',
          permalink_url: t.title_link ? u.origin + t.title_link : page, album: tr.current && tr.current.type === 'album' ? albumTitle : '', uploader: artist,
        }));
        // 曲のページの時：その曲が入っているアルバムのページ（あれば）。アーティストのページ
        const albumUrl = tr.album_url ? (String(tr.album_url).startsWith('http') ? String(tr.album_url) : u.origin + tr.album_url) : '';
        const out = { artist, album: albumTitle, type: (tr.current && tr.current.type) || '', artwork: art, url: page, albumUrl, artistUrl: u.origin, year: String((tr.current && (tr.current.release_date || tr.current.publish_date)) || '').match(/\d{4}/)?.[0] || '', tracks };
        const res = json(out, 200, cors);
        await caches.default.put(key, new Response(JSON.stringify(out), { headers: { 'Content-Type': 'application/json', 'Cache-Control': 'max-age=86400' } }));
        return res;
      }
      // ---- Bandcamp のアーティストの作品（アルバム・EP・シングル）: /bc/artist?url=https://xxx.bandcamp.com
      if (p === '/bc/artist') {
        let u; try { u = new URL(url.searchParams.get('url') || ''); } catch { return json({ error: 'bad url' }, 400, cors); }
        if (u.protocol !== 'https:' || !/^[a-z0-9-]+\.bandcamp\.com$/i.test(u.hostname)) return json({ error: 'bad url' }, 400, cors);
        const key = new Request('https://cache.otocloud/bca1/' + encodeURIComponent(u.origin));
        const hit = await caches.default.match(key); if (hit) return new Response(hit.body, { headers: { ...cors, 'Content-Type': 'application/json' } });
        const r = await fetch(u.origin + '/music', { headers: { 'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1' } });
        if (!r.ok) return json({ error: 'bandcamp ' + r.status }, 502, cors);
        const html = await r.text();
        const dec = (x) => String(x || '').replace(/&quot;/g, '"').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&#39;/g, "'").replace(/&amp;/g, '&');
        const imgOf = (id) => (id ? `https://f4.bcbits.com/img/a${String(id).padStart(10, '0')}_10.jpg` : '');
        const items = [], seen = new Set();
        const add = (x) => { if (!x.url || seen.has(x.url)) return; seen.add(x.url); items.push(x); };
        // 1作品しかない人は、作品のページにそのまま飛ばされる
        const tm = html.match(/data-tralbum="([^"]*)"/);
        if (tm) { try { const tr = JSON.parse(dec(tm[1])); add({ url: u.origin + (tr.url ? new URL(tr.url, u.origin).pathname : '/'), title: String((tr.current && tr.current.title) || ''), type: (tr.current && tr.current.type) || 'album', artwork: imgOf(tr.art_id) }); } catch {} }
        // 並んでいる作品
        for (const m of html.matchAll(/<li[^>]*data-item-id="(album|track)-\d+"[^>]*>([\s\S]*?)<\/li>/g)) {
          const href = (m[2].match(/<a href="([^"]+)"/) || [])[1]; if (!href) continue;
          const img = (m[2].match(/(?:data-original|src)="(https:\/\/f4\.bcbits\.com\/img\/[^"]+)"/) || [])[1] || '';
          const title = dec(((m[2].match(/<p class="title">([\s\S]*?)<\/p>/) || [])[1] || '').replace(/<[^>]+>[\s\S]*$/, '').trim());
          add({ url: new URL(href, u.origin).href.replace(/\?.*$/, ''), title, type: m[1], artwork: img.replace(/_\d+\.jpg$/, '_10.jpg') });
        }
        // 後から読み込まれる分（ページの中に JSON で入っている）
        const cm = html.match(/data-client-items="([^"]*)"/);
        if (cm) { try { for (const x of JSON.parse(dec(cm[1]))) add({ url: new URL(x.page_url, u.origin).href, title: String(x.title || ''), type: x.type || 'album', artwork: imgOf(x.art_id) }); } catch {} }
        const name = dec((html.match(/<meta property="og:title" content="([^"]*)"/) || [])[1] || (html.match(/<meta property="og:site_name" content="([^"]*)"/) || [])[1] || '');
        const photo = (html.match(/class="band-photo"[^>]*src="([^"]+)"/) || html.match(/<img[^>]*src="([^"]+)"[^>]*class="band-photo"/) || [])[1] || '';
        const out = { name, url: u.origin, photo: photo.replace(/_\d+\.jpg$/, '_10.jpg'), items: items.slice(0, 120) };
        await caches.default.put(key, new Response(JSON.stringify(out), { headers: { 'Content-Type': 'application/json', 'Cache-Control': 'max-age=21600' } }));
        return json(out, 200, cors);
      }
      // ---- だいたいの場所（地球儀用）: /where。ネットの接続元から、市くらいの粗さで（GPSは使わない）
      if (p === '/where') {
        const cf = request.cf || {};
        const r1 = (v) => (v == null || v === '' ? null : Math.round(Number(v) * 10) / 10);
        return json({ city: cf.city || '', country: cf.country || '', lat: r1(cf.latitude), lng: r1(cf.longitude) }, 200, cors);
      }
      // ---- その人のアルバム（EP・シングルも）: /user/123/albums
      m = p.match(/^\/user\/(\d{1,20})\/albums$/);
      if (m) {
        const d = await scGet(`/users/${m[1]}/playlists?limit=50&linked_partitioning=true&show_tracks=true`, env, userToken);
        const out = listOf(d)
          // アルバムを普通のプレイリストとして作っている人も多いので、その人が作ったものは全部出す
          .filter((pl) => pl && pl.track_count > 0)
          .map((pl) => ({ id: pl.id, title: pl.title, count: pl.track_count, artwork: plArt(pl), type: String(pl.set_type || pl.playlist_type || '').toLowerCase(), date: pl.release_date || pl.created_at || '' }));
        return json(out, 200, cors);
      }
      // ---- アルバムの中の曲（ログインなしでも）: /album/123
      m = p.match(/^\/album\/(\d{1,20})$/);
      if (m) {
        const d = await scGet(`/playlists/${m[1]}/tracks?limit=200&linked_partitioning=true&access=playable`, env, userToken);
        return json(listOf(d).map(mapTrack), 200, cors);
      }
      // ---- 波形: /wave/123（シークバーを波形にする。100本の高さ 0〜1）
      m = p.match(/^\/wave\/(\d{1,20})$/);
      if (m) {
        const st = url.searchParams.get('st') || '';
        const cache = caches.default;
        const raw = url.searchParams.get('mode') === 'raw';
        const key = new Request('https://cache.otocloud/wave2/' + m[1] + '/' + (url.searchParams.get('n') || '100') + (raw ? '/raw' : ''));
        const hit = await cache.match(key);
        if (hit) return json(await hit.json(), 200, cors);
        const t = await trackInfo(m[1], env, userToken, st);
        const wu = t && t.waveform ? t.waveform.replace(/\.png(\?.*)?$/, '.json') : '';
        if (!/^https:\/\/wave[0-9]*\.sndcdn\.com\//.test(wu)) return json({ error: 'no waveform' }, 404, cors);
        const r = await fetch(wu);
        if (!r.ok) return json({ error: 'wave ' + r.status }, 502, cors);
        const d = await r.json();
        const s = d.samples || [], n = Math.min(240, Math.max(40, Number(url.searchParams.get('n')) || 100)), h = d.height || 140, bars = [];
        for (let i = 0; i < n; i++) {
          const a = Math.floor(i * s.length / n), b = Math.max(a + 1, Math.floor((i + 1) * s.length / n));
          // 区間の平均（一番大きい1点だと、曲の終わりのフェードアウトが最後まで高く見えるため）
          // raw：区間の真ん中の1点だけ（SoundCloud公式のように、となり同士の高さがばらつく＝ギザギザが残る）
          if (raw) { const c = Math.floor((a + b) / 2); bars.push(Math.round((s[c] || 0) / h * 1000) / 1000); continue; }
          let sum = 0; for (let k = a; k < b; k++) sum += s[k] || 0;
          bars.push(Math.round(sum / (b - a) / h * 1000) / 1000);
        }
        await cache.put(key, new Response(JSON.stringify(bars), { headers: { 'Cache-Control': 'public, max-age=604800', 'Content-Type': 'application/json' } }));
        return json(bars, 200, cors);
      }
      // ---- 共有ページ: /s/123（インスタ・LINEなどで、ジャケット付きのカードになって、その場で再生できる）
      m = p.match(/^\/s\/(\d{1,20})$/);
      if (m) return sharePage(m[1], env, url.searchParams.get('st') || '');

      // ---- ジャケット画像の中継: /img?u=（SoundCloudの画像だけ）
      // シェア用の画像を作る時に、ブラウザがジャケットを読み込めるようにする
      // 地球儀用：アーティストの場所をまとめて調べる（SoundCloudはプロフィールの街、ほかは MusicBrainz の出身地）。
      // 1回で調べる数には上限。残りは pending で返すので、画面がもう一度聞く
      // アーティストの国（日本の人かどうか）：Spotify の番号から MusicBrainz で。90日覚えておく。POST { artists: [{ sp, name }] } → { sp番号: 'JP' | 'US' | '' }
      if (p === '/artists/country' && request.method === 'POST') {
        const body = await request.json().catch(() => ({}));
        const list = Array.isArray(body.artists) ? body.artists.slice(0, 60) : [];
        const out = {}; let budget = 4;
        for (const a of list) {
          if (!a || !a.sp) continue;
          const ck = new Request('https://cache.otocloud/country1/' + encodeURIComponent(a.sp));
          const hit = await caches.default.match(ck);
          if (hit) { out[a.sp] = (await hit.json()).c; continue; }
          if (budget-- <= 0) continue;
          let c = null;
          try {
            let id = '';
            const r = await fetch('https://musicbrainz.org/ws/2/url?inc=artist-rels&fmt=json&resource=' + encodeURIComponent('https://open.spotify.com/artist/' + a.sp), { headers: MB_H });
            if (r.ok) { const d = await r.json(); const rel = (d.relations || []).find((x) => x.artist); if (rel) id = rel.artist.id; }
            await nap(1100);
            if (!id && a.name) {
              const q = await fetch('https://musicbrainz.org/ws/2/artist?fmt=json&limit=5&query=' + encodeURIComponent('artist:"' + String(a.name).replace(/"/g, '') + '"'), { headers: MB_H });
              if (q.ok) { const d = await q.json(); const best = (d.artists || []).find((x) => x.score >= 95 && String(x.name).toLowerCase() === String(a.name).toLowerCase()); if (best) { c = best.country || (best.area && best.area['iso-3166-1-codes'] && best.area['iso-3166-1-codes'][0]) || ''; } }
              await nap(1100);
            } else if (id) {
              const q = await fetch(`https://musicbrainz.org/ws/2/artist/${id}?fmt=json`, { headers: MB_H });
              if (q.ok) { const d = await q.json(); c = d.country || (d.area && d.area['iso-3166-1-codes'] && d.area['iso-3166-1-codes'][0]) || ''; }
              await nap(1100);
            }
          } catch {}
          if (c === null) c = '';
          out[a.sp] = c;
          await caches.default.put(ck, new Response(JSON.stringify({ c }), { headers: { 'Cache-Control': 'max-age=7776000' } }));
        }
        return json(out, 200, cors);
      }
      if (p === '/artists/where' && request.method === 'POST') {
        const body = await request.json().catch(() => ({}));
        const list = Array.isArray(body.artists) ? body.artists.slice(0, 150) : [];
        let mbBudget = 5, scBudget = 25, geoBudget = 25, pending = 0;
        const out = [];
        for (const a of list) {
          if (!a || !a.key) continue;
          const id = a.sc ? 'sc:' + a.sc : a.sp ? 'sp:' + a.sp : 'n:' + String(a.name || '').toLowerCase().trim();
          const ck = new Request('https://cache.otocloud/where2/' + encodeURIComponent(id));
          const hit = await caches.default.match(ck);
          if (hit) { const g = await hit.json(); if (g.lat != null) out.push({ key: a.key, ...g }); continue; }
          let loc = null;
          if (a.sc && /^\d{1,20}$/.test(String(a.sc))) {
            if (scBudget-- <= 0) { pending++; continue; }
            try { const u = await scGet(`/users/${a.sc}`, env); loc = { city: String(u.city || '').trim(), country: String(u.country || u.country_code || '').trim() }; } catch { pending++; continue; }
          } else {
            if (!a.name || mbBudget-- <= 0) { pending++; continue; }
            loc = await mbArea(a);
            if (!loc) { pending++; continue; }
          }
          let g = { lat: null };
          if (loc.city || loc.country) {
            const r = await geocode(loc.city, loc.country, geoBudget-- > 0);
            if (!r) { pending++; continue; }
            if (r.lat != null) g = { lat: r.lat, lng: r.lng, place: r.name };
          }
          await caches.default.put(ck, new Response(JSON.stringify(g), { headers: { 'Content-Type': 'application/json', 'Cache-Control': 'public, max-age=2592000' } }));
          if (g.lat != null) out.push({ key: a.key, ...g });
        }
        return json({ located: out, pending }, 200, cors);
      }

      // Spotify・Bandcamp の曲の歌詞：曲名とアーティストで LRCLIB（みんなで作る歌詞のデータベース）を探す
      if (p === '/lyrics/by') {
        const title = String(url.searchParams.get('title') || '').slice(0, 200), artist = String(url.searchParams.get('artist') || '').split(/,| feat\.? | ft\.? /i)[0].trim().slice(0, 120);
        const dur = Number(url.searchParams.get('dur') || 0);
        if (!title) return json({ lyrics: '' }, 200, cors);
        const l = await lrclib({ title, publisher_metadata: { artist }, duration: dur * 1000 });
        return json(l || { lyrics: '' }, 200, cors);
      }

      // Genius の歌詞ページ（本文は取らない。曲のページへのリンクだけ）。
      // 曲名とアーティストがちゃんと合っていて、歌詞が載っているページだけ返す（無ければ url なし＝ボタンを出さない）
      if (p === '/genius') {
        const title = String(url.searchParams.get('title') || '').slice(0, 200), artist = String(url.searchParams.get('artist') || '').slice(0, 120);
        if (!title) return json({ url: '' }, 200, cors);
        const ck = new Request('https://cache.otocloud/genius2/' + encodeURIComponent((artist + '|' + title).toLowerCase()));
        const hit0 = await caches.default.match(ck);
        if (hit0) return json(await hit0.json(), 200, cors);
        const norm = (x) => String(x || '').toLowerCase().normalize('NFKC').replace(/[([{【].*?[)\]}】]/g, ' ').replace(/\s(feat|ft)\.?\s.*$/, '').replace(/[^\p{L}\p{N}]+/gu, '');
        const first = (x) => String(x || '').split(/\s*(?:,|&|×|\bx\b|\bfeat\b\.?|\bft\b\.?|\bwith\b)\s*/i)[0];
        const wantT = norm(title), wantA = norm(first(artist));
        let out = { url: '' };
        try {
          let hits = [];
          if (env.GENIUS_TOKEN) {
            const r = await fetch('https://api.genius.com/search?q=' + encodeURIComponent(first(artist) + ' ' + title), { headers: { Authorization: 'Bearer ' + env.GENIUS_TOKEN } });
            const d = await r.json(); hits = ((d.response && d.response.hits) || []).map((h) => h.result).filter(Boolean);
          } else {
            const r = await fetch('https://genius.com/api/search/song?per_page=5&q=' + encodeURIComponent(first(artist) + ' ' + title), { headers: { 'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1', 'Accept': 'application/json' } });
            const d = await r.json(); const secs = (d.response && d.response.sections) || [];
            hits = secs.flatMap((sct) => (sct.hits || []).map((h) => h.result)).filter(Boolean);
          }
          const ok = hits.find((h) => h.url && /^https:\/\/genius\.com\//.test(h.url) && norm(h.title) === wantT
            && (norm(first(h.primary_artist && h.primary_artist.name)) === wantA || norm(h.artist_names || '').includes(wantA))
            && (!h.lyrics_state || h.lyrics_state === 'complete') && !h.instrumental);
          if (ok) out = { url: ok.url, title: ok.full_title || ok.title };
        } catch {}
        await caches.default.put(ck, new Response(JSON.stringify(out), { headers: { 'Content-Type': 'application/json', 'Cache-Control': 'public, max-age=' + (out.url ? 604800 : 86400) } }));
        return json(out, 200, cors);
      }

      // 出どころのロゴ（各サービスが自分のサイトで配っている公式アイコン）。1週間キャッシュ
      m = p.match(/^\/logo\/(sc|bc|am|sp)$/);
      if (m) {
        const L = {
          sc: 'https://m.sndcdn.com/_next/static/images/apple-touch-icon-180-dd8465ef631c16f24df540ad961c3d12.png',
          bc: 'https://s4.bcbits.com/client-bundle/1/PageLayout_1/favicon-e91a942bb76c26f619d5945a00cf8e60.static/favicon/apple-touch-icon.png',
          am: 'https://music.apple.com/assets/favicon/favicon-180.png',
          sp: 'https://www.scdn.co/i/_global/touch-icon-144.png',
        };
        const r = await fetch(L[m[1]], { cf: { cacheTtl: 604800, cacheEverything: true } });
        if (!r.ok) return json({ error: 'logo ' + r.status }, 502, cors);
        const h = new Headers(cors);
        h.set('Content-Type', 'image/png');
        h.set('Cache-Control', 'public, max-age=604800');
        return new Response(r.body, { status: 200, headers: h });
      }
      // 各サービスの公式アイコン（ページに書かれている icon のリンク）を一覧で返す
      if (p === '/icons') {
        let u;
        try { u = new URL(url.searchParams.get('u') || ''); } catch { return json({ error: 'u が不正です' }, 400, cors); }
        if (u.protocol !== 'https:' || !/(^|\.)(soundcloud\.com|bandcamp\.com|apple\.com|spotify\.com)$/.test(u.hostname)) return json({ error: 'このサイトは使えません' }, 400, cors);
        const r = await fetch(u.toString(), { headers: { 'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1' } });
        const html = await r.text();
        const out = [];
        for (const m of html.matchAll(/<link[^>]+>/gi)) {
          const t = m[0];
          if (!/rel=["'][^"']*icon/i.test(t)) continue;
          const h = (t.match(/href=["']([^"']+)/i) || [])[1];
          if (h) out.push({ tag: t.slice(0, 200), href: new URL(h, u).toString() });
        }
        return json({ status: r.status, icons: out }, 200, cors);
      }
      if (p === '/img') {
        let u;
        try { u = new URL(url.searchParams.get('u') || ''); } catch { return json({ error: 'u が不正です' }, 400, cors); }
        if (u.protocol !== 'https:' || !/(^|\.)(sndcdn\.com|soundcloud\.com|bcbits\.com|bandcamp\.com|apple\.com|mzstatic\.com|scdn\.co|spotifycdn\.com|spotify\.com)$/.test(u.hostname)) return json({ error: 'この画像は使えません' }, 400, cors);
        const r = await fetch(u.toString(), { cf: { cacheTtl: 86400, cacheEverything: true } });
        if (!r.ok) return json({ error: 'img ' + r.status }, r.status, cors);
        const h = new Headers(cors);
        h.set('Content-Type', r.headers.get('Content-Type') || 'image/jpeg');
        h.set('Cache-Control', 'public, max-age=86400');
        return new Response(r.body, { status: 200, headers: h });
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
        // ほかのサーバーでも同じ曲のアドレスを使い回す（一緒に聴いている2人や、くり返し聴く時に、SoundCloudへの再生の数を増やさない）
        const pk = new Request('https://cache.otocloud/play/' + id);
        const shared = await caches.default.match(pk);
        if (shared) { const body = await shared.json(); playCache.set(id, { body, exp: Date.now() + 8 * 60 * 1000 }); return json(body, 200, cors); }
        const cands = await candidates(id, env, userToken);
        const token = userToken || await getToken(env);
        const tried = [];
        for (const c of cands) {
          const r = await fetch(c.apiUrl, { headers: { 'Authorization': `OAuth ${token}` }, redirect: 'manual' });
          const loc = r.headers.get('Location');
          // SoundCloudが教えてくれる「残りの回数」を覚えておく（/quota で見られる）
          const q = {}; for (const [k, v] of r.headers) if (/ratelimit|retry-after/i.test(k)) q[k] = v;
          q.at = new Date().toISOString(); q.status = r.status;
          await caches.default.put(new Request('https://cache.otocloud/quota'), new Response(JSON.stringify(q), { headers: { 'Cache-Control': 'public, max-age=172800' } }));
          tried.push({ kind: c.kind, status: r.status });
          if (loc) {
            const body = { kind: c.kind, hls: c.hls, url: loc };
            playCache.set(id, { body, exp: Date.now() + 10 * 60 * 1000 });
            await caches.default.put(pk, new Response(JSON.stringify(body), { headers: { 'Content-Type': 'application/json', 'Cache-Control': 'public, max-age=480' } }));
            return json(body, 200, cors);
          }
        }
        return json({ error: 'この曲は再生できません', tried }, 404, cors);
      }

      // ---- 再生の残り回数（SoundCloudが最後に教えてくれた値）
      if (p === '/quota') {
        const hit = await caches.default.match(new Request('https://cache.otocloud/quota'));
        return json(hit ? await hit.json() : { none: true }, 200, cors);
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
        // Otocloudにログインしていて、この通話の当事者である人だけに発行する
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

      // ---- Spotify の合鍵の交換・更新（iPhone アプリの Spotify SDK から呼ばれる）
      // 秘密の鍵（SPOTIFY_CLIENT_SECRET）はここ（Cloudflare の Secrets）にだけ置く。アプリやページには入れない
      if ((p === '/spotify/swap' || p === '/spotify/refresh') && request.method === 'POST') {
        if (!env.SPOTIFY_CLIENT_SECRET) return json({ error: 'SPOTIFY_CLIENT_SECRET が未設定です' }, 500, cors);
        const form = new URLSearchParams(await request.text());
        const body = new URLSearchParams();
        if (p === '/spotify/swap') {
          body.set('grant_type', 'authorization_code');
          body.set('code', form.get('code') || '');
          body.set('redirect_uri', 'app.otocloud://spotify-callback');
        } else {
          body.set('grant_type', 'refresh_token');
          body.set('refresh_token', form.get('refresh_token') || '');
        }
        const r = await fetch('https://accounts.spotify.com/api/token', {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded', Authorization: 'Basic ' + btoa('1ff4e8ebb2f94fb5a20149d697df21fc:' + env.SPOTIFY_CLIENT_SECRET) },
          body,
        });
        const out = new Response(await r.text(), { status: r.status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });
        return out;
      }

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
          // いいねが多い人のために、続きのページもたどる（最大3,000曲。それより古いものは出ない）
          let r = await scUser('/me/likes/tracks?limit=200&linked_partitioning=true&access=playable', userToken);
          if (!r.ok) return json({ error: 'likes ' + r.status }, r.status, cors);
          const all = listOf(r.body);
          for (let i = 0; i < 14 && r.ok && r.body && r.body.next_href && all.length < 3000; i++) {
            const next = String(r.body.next_href);
            if (!next.startsWith(API)) break;
            r = await scUser(next.slice(API.length), userToken);
            if (r.ok) all.push(...listOf(r.body));
          }
          const seen = new Set();
          return json(all.filter((t) => t && !seen.has(t.id) && seen.add(t.id)).map(mapTrack), 200, cors);
        }

        // フォローしているアーティスト（地球儀用）。プロフィールの街・国から場所（緯度・経度）を出す
        if (p === '/sc/followings') {
          let r = await scUser('/me/followings?limit=200&linked_partitioning=true', userToken);
          if (!r.ok) return json({ error: 'followings ' + r.status }, r.status, cors);
          const all = listOf(r.body);
          for (let i = 0; i < 4 && r.ok && r.body && r.body.next_href && all.length < 1000; i++) {
            const next = String(r.body.next_href);
            if (!next.startsWith(API)) break;
            r = await scUser(next.slice(API.length), userToken);
            if (r.ok) all.push(...listOf(r.body));
          }
          const people = all.filter((u) => u && u.id).map((u) => ({
            id: String(u.id), name: u.username || u.full_name || '', avatar: u.avatar_url || '',
            city: String(u.city || '').trim(), country: String(u.country || u.country_code || '').trim(), followers: u.followers_count || 0,
          }));
          // 同じ街はまとめて1回だけ調べる（1回で調べる数には上限。残りは次に開いた時に）
          const places = new Map();
          for (const u of people) if (u.city || u.country) places.set((u.city + '|' + u.country).toLowerCase(), null);
          let budget = 30;
          for (const k of places.keys()) {
            const [city, country] = k.split('|');
            const g = await geocode(city, country, budget > 0);
            if (g && g.fresh) budget--;
            places.set(k, g);
          }
          const out = people.map((u) => {
            const g = places.get((u.city + '|' + u.country).toLowerCase());
            return g && g.lat != null ? { ...u, lat: g.lat, lng: g.lng, place: g.name } : null;
          }).filter(Boolean);
          return json({ total: people.length, located: out.length, artists: out }, 200, cors);
        }

        // この曲にコメント・いいねした人を、プロフィールの場所つきで: /sc/listeners?id=TRACK
        if (p === '/sc/listeners') {
          const id = url.searchParams.get('id') || '';
          if (!/^\d{1,20}$/.test(id)) return json({ error: 'bad id' }, 400, cors);
          const [c, f] = await Promise.all([scUser(`/tracks/${id}/comments?limit=200&linked_partitioning=true`, userToken), scUser(`/tracks/${id}/favoriters?limit=200&linked_partitioning=true`, userToken)]);
          const seen = new Map();
          const add = (u, src) => { if (!u || !u.id || seen.has(String(u.id))) return; seen.set(String(u.id), { id: String(u.id), name: u.username || u.full_name || '', avatar: u.avatar_url || '', city: String(u.city || '').trim(), country: String(u.country || u.country_code || '').trim(), src, hasPlace: 'city' in u || 'country_code' in u || 'country' in u }); };
          if (c.ok) for (const cm of listOf(c.body)) add(cm && cm.user, 'comment');
          if (f.ok) for (const u of listOf(f.body)) add(u, 'like');
          const people = [...seen.values()].slice(0, 300);
          // コメントの人は場所が付いてこないことがあるので、足りない人だけプロフィールを見に行く（多すぎないように）
          const need = people.filter((u) => !u.hasPlace).slice(0, 60);
          for (let i = 0; i < need.length; i += 12) {
            await Promise.all(need.slice(i, i + 12).map(async (u) => { const r = await scUser(`/users/${u.id}`, userToken); if (r.ok && r.body) { u.city = String(r.body.city || '').trim(); u.country = String(r.body.country || r.body.country_code || '').trim(); } }));
          }
          const places = new Map();
          for (const u of people) if (u.city || u.country) places.set((u.city + '|' + u.country).toLowerCase(), null);
          let budget = 30;
          for (const k of places.keys()) { const [city, country] = k.split('|'); const g = await geocode(city, country, budget > 0); if (g && g.fresh) budget--; places.set(k, g); }
          const out = people.map((u) => { const g = places.get((u.city + '|' + u.country).toLowerCase()); return g && g.lat != null ? { id: u.id, name: u.name, avatar: u.avatar, src: u.src, lat: g.lat, lng: g.lng, place: g.name } : null; }).filter(Boolean);
          return json({ total: people.length, comments: c.ok ? listOf(c.body).length : -c.status, likes: f.ok ? listOf(f.body).length : -f.status, located: out.length, people: out }, 200, cors);
        }

        // SoundCloudでその人をフォローしているか／フォローする／外す: /sc/follow?id=123（GET / PUT / DELETE）
        if (p === '/sc/follow') {
          const id = url.searchParams.get('id') || '';
          if (!/^\d{1,20}$/.test(id)) return json({ error: 'bad id' }, 400, cors);
          const method = request.method === 'PUT' ? 'PUT' : request.method === 'DELETE' ? 'DELETE' : 'GET';
          const r = await scUser(`/me/followings/${id}`, userToken, method);
          if (method === 'GET') return json({ following: r.ok }, 200, cors);
          if (!r.ok && r.status !== 404) return json({ error: 'follow ' + r.status }, r.status, cors);
          return json({ ok: true, following: method === 'PUT' }, 200, cors);
        }

        // 自分がアップロードした曲
        if (p === '/sc/tracks') {
          const r = await scUser('/me/tracks?limit=50&linked_partitioning=true', userToken);
          if (!r.ok) return json({ error: 'tracks ' + r.status }, r.status, cors);
          return json(listOf(r.body).map(mapTrack), 200, cors);
        }

        // 自分のプレイリスト一覧
        if (p === '/sc/playlists') {
          const r = await scUser('/me/playlists?limit=50&show_tracks=true&linked_partitioning=true', userToken);
          if (!r.ok) return json({ error: 'playlists ' + r.status }, r.status, cors);
          return json(listOf(r.body).map((pl) => ({ id: pl.id, title: pl.title, count: pl.track_count, artwork: plArt(pl) })), 200, cors);
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
