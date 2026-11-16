// Aurora license server: a Cloudflare Worker with one KV namespace.
//
// KV holds only the SHA-256 of each activation key, never the key itself:
//   key:<sha256 hex> -> {status: new|active|revoked, kc, ifv, days, until,
//                        rebinds, created, activated}
//   sub:<first 8 hex> -> <sha256 hex>      (to find a key by its lease subject)
//   rl:<ip>           -> attempts this hour (slows down key guessing)
//
// Leases use the format of Aurora/Core/lease: base64url(JSON claims) + "." +
// base64url(Ed25519 signature over the first part). Secrets: SERVER_PRIVATE_KEY
// (base64 PKCS#8, from `aurora-license secret`) and ADMIN_TOKEN.

const ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
const LEASE_DAYS = 30;
const ATTEMPTS_PER_HOUR = 30;

const enc = new TextEncoder();

function b64url(bytes) {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function sha256Hex(text) {
  const d = new Uint8Array(await crypto.subtle.digest("SHA-256", enc.encode(text)));
  return [...d].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function checksum(data) {
  const d = new Uint8Array(await crypto.subtle.digest("SHA-256", enc.encode(data)));
  const v = ((d[0] << 8) | d[1]) >> 6;
  return ALPHABET[v >> 5] + ALPHABET[v & 31];
}

// The same rules as lease.NormalizeKey: case, dashes and spaces do not
// matter, O reads as 0 and I/L as 1, the last two characters are a checksum.
async function normalizeKey(s) {
  let t = String(s || "").toUpperCase().replace(/[-\s_]/g, "");
  if (t.startsWith("AUR")) t = t.slice(3);
  if (t.length !== 20) return null;
  t = t.replace(/O/g, "0").replace(/[IL]/g, "1");
  for (const c of t) if (!ALPHABET.includes(c)) return null;
  if ((await checksum(t.slice(0, 18))) !== t.slice(18)) return null;
  return "AUR-" + t.match(/.{5}/g).join("-");
}

async function newKey() {
  const r = crypto.getRandomValues(new Uint8Array(18));
  const data = [...r].map((v) => ALPHABET[v & 31]).join("");
  const t = data + (await checksum(data));
  return "AUR-" + t.match(/.{5}/g).join("-");
}

let signingKey;
async function signLease(env, claims) {
  if (!signingKey) {
    const der = Uint8Array.from(atob(env.SERVER_PRIVATE_KEY.trim()), (c) => c.charCodeAt(0));
    signingKey = await crypto.subtle.importKey("pkcs8", der, { name: "Ed25519" }, false, ["sign"]);
  }
  const head = b64url(enc.encode(JSON.stringify({ v: 1, kid: "server", ...claims })));
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "Ed25519" }, signingKey, enc.encode(head)));
  return head + "." + b64url(sig);
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json; charset=utf-8" } });
}

const fail = (status, error) => json({ error }, status);
const now = () => Math.floor(Date.now() / 1000);

async function rateLimited(env, request) {
  const ip = request.headers.get("cf-connecting-ip") || "unknown";
  const k = "rl:" + ip;
  const n = parseInt((await env.LICENSES.get(k)) || "0", 10);
  if (n >= ATTEMPTS_PER_HOUR) return true;
  await env.LICENSES.put(k, String(n + 1), { expirationTtl: 3600 });
  return false;
}

// Activation and refresh are the same call: the first device binds the key,
// the same device (Keychain id OR identifierForVendor) gets a fresh lease,
// any other device is refused.
async function activate(env, request) {
  if (await rateLimited(env, request)) return fail(429, "Слишком много попыток, подождите час");
  let body;
  try { body = await request.json(); } catch { return fail(400, "Неверный запрос"); }
  const key = await normalizeKey(body.key);
  const kc = String(body.kc || "").trim(), ifv = String(body.ifv || "").trim();
  if (!key) return fail(400, "Ключ введён с ошибкой");
  if (!kc && !ifv) return fail(400, "Нет кода устройства");
  const hash = await sha256Hex(key);
  const raw = await env.LICENSES.get("key:" + hash);
  if (!raw) return fail(404, "Ключ не найден");
  const rec = JSON.parse(raw);
  const t = now();
  if (rec.status === "revoked") return fail(403, "Ключ отозван");
  if (rec.status === "active") {
    const same = (rec.kc && kc && rec.kc.toLowerCase() === kc.toLowerCase()) || (rec.ifv && ifv && rec.ifv.toLowerCase() === ifv.toLowerCase());
    if (!same) return fail(409, "Ключ уже активирован на другом устройстве");
    if (kc) rec.kc = kc; // a reinstall changes one half: keep both current
    if (ifv) rec.ifv = ifv;
  } else {
    rec.status = "active";
    rec.kc = kc;
    rec.ifv = ifv;
    rec.activated = t;
    rec.until = rec.days > 0 ? t + rec.days * 86400 : 0;
  }
  if (rec.until && t > rec.until) return fail(403, "Срок действия ключа истёк");
  await env.LICENSES.put("key:" + hash, JSON.stringify(rec));
  let exp = t + LEASE_DAYS * 86400;
  if (rec.until && rec.until < exp) exp = rec.until;
  const lease = await signLease(env, { sub: hash.slice(0, 8), kc: rec.kc, ifv: rec.ifv, iat: t, exp, st: t });
  return json({ lease, until: rec.until || 0 });
}

async function findHash(env, body) {
  if (body.key) {
    const k = await normalizeKey(body.key);
    return k ? sha256Hex(k) : null;
  }
  if (body.sub) return env.LICENSES.get("sub:" + String(body.sub).toLowerCase());
  return null;
}

async function admin(env, request, action) {
  const auth = request.headers.get("authorization") || "";
  if (!env.ADMIN_TOKEN || auth !== "Bearer " + env.ADMIN_TOKEN.trim()) return fail(401, "Нет доступа");
  if (action === "list" && request.method === "GET") {
    const keys = [];
    let cursor;
    do {
      const page = await env.LICENSES.list({ prefix: "key:", cursor });
      for (const k of page.keys) {
        const rec = JSON.parse((await env.LICENSES.get(k.name)) || "{}");
        keys.push({ sub: k.name.slice(4, 12), status: rec.status, kc: rec.kc || "", ifv: rec.ifv || "", until: rec.until || 0,
          days: rec.days || 0, rebinds: rec.rebinds || 0, created: rec.created || 0, activated: rec.activated || 0 });
      }
      cursor = page.list_complete ? undefined : page.cursor;
    } while (cursor);
    return json({ keys });
  }
  if (request.method !== "POST") return fail(405, "Нужен POST");
  let body;
  try { body = await request.json(); } catch { return fail(400, "Неверный запрос"); }
  if (action === "issue") {
    const n = Math.min(Math.max(parseInt(body.n, 10) || 1, 1), 500);
    const days = Math.min(Math.max(parseInt(body.days, 10) || 0, 0), 3650);
    const keys = [];
    for (let i = 0; i < n; i++) {
      const key = await newKey();
      const hash = await sha256Hex(key);
      await env.LICENSES.put("key:" + hash, JSON.stringify({ status: "new", days, rebinds: 0, created: now() }));
      await env.LICENSES.put("sub:" + hash.slice(0, 8), hash);
      keys.push(key);
    }
    return json({ keys, days });
  }
  const hash = await findHash(env, body);
  const raw = hash && (await env.LICENSES.get("key:" + hash));
  if (!raw) return fail(404, "Ключ не найден");
  const rec = JSON.parse(raw);
  if (action === "reset") {
    // Free the key for a new device; the old one keeps its lease until it expires.
    rec.status = "new";
    rec.kc = "";
    rec.ifv = "";
    rec.rebinds = (rec.rebinds || 0) + 1;
  } else if (action === "revoke") {
    rec.status = "revoked";
  } else {
    return fail(404, "Нет такого действия");
  }
  await env.LICENSES.put("key:" + hash, JSON.stringify(rec));
  return json({ sub: hash.slice(0, 8), status: rec.status });
}

export default {
  async fetch(request, env) {
    const path = new URL(request.url).pathname.replace(/\/+$/, "");
    try {
      if (request.method === "POST" && (path === "/activate" || path === "/refresh")) return await activate(env, request);
      if (path.startsWith("/admin/")) return await admin(env, request, path.slice(7));
      if (path === "" || path === "/health") return json({ ok: true });
      return fail(404, "Нет такого адреса");
    } catch (e) {
      return fail(500, "Ошибка сервера лицензий");
    }
  },
};
