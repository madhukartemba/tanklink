/**
 * TankLink report service.
 *
 * POST /v1/report from the app → full report saved as a file in a private
 * GitHub repo, plus an issue per distinct problem. Reports with the same
 * fingerprint add a comment to the open issue instead of opening a new one.
 *
 * Body (JSON):
 *   app_key      string   shared key baked into the app (stops casual spam)
 *   fingerprint  string   groups duplicates, built by the app
 *   title        string   issue title for a new problem
 *   labels       string[] e.g. ["pump-err-3", "pump-0.14.0", "app-1.3.0"]
 *   summary      string   short markdown-free text: description + versions
 *   report_text  string   the full report the user previewed
 *   contact      string   optional email the user gave for follow-up
 *
 * Response: 200 {"id": "K7Q2MX"} | 4xx/5xx {"error": "..."}
 *
 * GET /v1/releases → the TankLink repo's GitHub release list, exactly as
 * GitHub's API returns it, cached for RELEASES_FRESH_SEC. Every phone's
 * update check comes here, so GitHub sees a handful of calls an hour (made
 * with GITHUB_TOKEN: 5,000 an hour) however many phones there are. If
 * GitHub fails, the last copy is served for up to a day. Supports
 * If-None-Match with GitHub's ETag.
 *
 * GET /v1/firmware/pump/latest?hw=<rev>&proto=<major> → the newest pump
 * firmware this board can take, small enough for the pump to parse:
 * {"version","url","size","sha256"}. Same rules as the app: highest semver
 * among pump-v* releases, skipping any whose manifest proto_major differs or
 * whose hw_revs lacks the board. Cached like the release list. The pump
 * checks the sha256 itself and the image must be signed with the TankLink
 * key, so a wrong answer here can't make a pump run foreign code.
 *
 * GET /v1/firmware/pump/download/<version>.bin → that release's pump_node.bin,
 * streamed through this Worker. The "latest" answer points here, not at
 * GitHub, so the pump only ever talks to this host: GitHub's download host
 * (release-assets.githubusercontent.com) is not reachable from every network,
 * and its redirect carries a very long signed address. Only pump_node.bin of a
 * pump-v* release of RELEASES_REPO can be fetched this way.
 *
 * POST /v1/refresh (header x-refresh-key: REFRESH_KEY) → forget the cached
 * release list now and fetch it again, so a release you just published (or
 * deleted) shows up at once instead of within RELEASES_FRESH_SEC. The pump's
 * "latest" answers follow the list, so they refresh with it. Without a
 * REFRESH_KEY secret the endpoint does not exist. scripts/refresh_worker.sh.
 *
 * GET /app → 302 to TankLink.apk of the newest app-v* release (from the
 * same cached list). The install QR code points here, so it never has to
 * change. Falls back to the GitHub releases page.
 *
 * GET /.well-known/assetlinks.json → Android App Links: lets the TankLink
 * app (signed with the upload key) open https://<this host>/pump links,
 * such as the one on the pump's NFC tag. GET /pump[/...] → 302 to the landing
 * page, for a phone without the app.
 */

const MAX_BODY_BYTES = 200 * 1024;
const MAX_TITLE = 120;
const MAX_SUMMARY = 4000;
const MAX_LABELS = 8;
const CONTACT_LABEL = "has-contact";
// Loose: one @, a dot after it, no spaces or markdown-breaking characters.
const EMAIL_RE = /^[^\s@`<>]+@[^\s@`<>]+\.[^\s@`<>]+$/;
const GH_API = "https://api.github.com";
const RELEASES_FRESH_SEC = 600;
const RELEASES_KEEP_SEC = 86400;
const RELEASES_PER_PAGE = 30;
const APP_FALLBACK_URL = "https://github.com/madhukartemba/tanklink/releases";
// SHA-256 of the app's upload key certificate (docs/app-release.md).
const ASSET_LINKS = [
  {
    relation: ["delegate_permission/common.handle_all_urls"],
    target: {
      namespace: "android_app",
      package_name: "com.tanklink.tanklink",
      sha256_cert_fingerprints: [
        "D4:00:00:75:A2:50:3D:04:C9:D1:9C:4E:44:0D:FD:06:56:14:0C:35:37:98:09:29:0F:DF:A7:21:67:EC:C3:A1",
      ],
    },
  },
];

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/health") {
      return json({ ok: true });
    }
    if (url.pathname === "/app" || url.pathname === "/app/") {
      return appDownload(env);
    }
    if (url.pathname === "/.well-known/assetlinks.json") {
      return json(ASSET_LINKS);
    }
    if (url.pathname === "/pump" || url.pathname.startsWith("/pump/")) {
      return Response.redirect(new URL("/", url).toString(), 302);
    }
    if (url.pathname === "/v1/releases") {
      if (request.method !== "GET") {
        return json({ error: "method not allowed" }, 405);
      }
      return releases(request, env);
    }
    if (url.pathname === "/v1/firmware/pump/latest") {
      if (request.method !== "GET") {
        return json({ error: "method not allowed" }, 405);
      }
      return pumpLatest(url, env);
    }
    if (url.pathname === "/v1/refresh") {
      if (request.method !== "POST" || !env.REFRESH_KEY) {
        return json({ error: "not found" }, 404);
      }
      const given = request.headers.get("x-refresh-key") || "";
      if (!(await sameSecret(given, env.REFRESH_KEY))) {
        return json({ error: "bad key" }, 401);
      }
      return refreshReleases(env);
    }
    const dl = /^\/v1\/firmware\/pump\/download\/(\d+\.\d+\.\d+)\.bin$/.exec(url.pathname);
    if (dl) {
      if (request.method !== "GET") {
        return json({ error: "method not allowed" }, 405);
      }
      return pumpDownload(dl[1], env);
    }
    if (url.pathname !== "/v1/report") {
      return json({ error: "not found" }, 404);
    }
    if (request.method !== "POST") {
      return json({ error: "method not allowed" }, 405);
    }

    // APP_KEY ships inside the app, so it is not a secret: these limits are
    // what keep a flood out of the reports repo and off GITHUB_TOKEN's quota.
    if (env.REPORT_LIMITER) {
      const ip = request.headers.get("cf-connecting-ip") || "unknown";
      const { success } = await env.REPORT_LIMITER.limit({ key: ip });
      if (!success) return json({ error: "too many reports" }, 429);
    }
    if (env.GLOBAL_LIMITER) {
      const { success } = await env.GLOBAL_LIMITER.limit({ key: "all" });
      if (!success) return json({ error: "too many reports" }, 429);
    }

    const len = Number(request.headers.get("content-length") || "0");
    if (len > MAX_BODY_BYTES) return json({ error: "too large" }, 413);
    const raw = await request.text();
    if (raw.length > MAX_BODY_BYTES) return json({ error: "too large" }, 413);

    let body;
    try {
      body = JSON.parse(raw);
    } catch {
      return json({ error: "bad json" }, 400);
    }

    if (!env.APP_KEY || body.app_key !== env.APP_KEY) {
      return json({ error: "bad key" }, 401);
    }
    const problem = validate(body);
    if (typeof problem === "string") return json({ error: problem }, 400);

    try {
      const id = await fileReport(env, problem);
      return json({ id });
    } catch (e) {
      console.error("report failed", e && e.message);
      return json({ error: "could not save report" }, 502);
    }
  },
};

/** Returns a clean report or an error string. */
function validate(b) {
  const str = (v) => (typeof v === "string" ? v : "");
  const fingerprint = str(b.fingerprint).trim();
  const title = oneLine(str(b.title)).slice(0, MAX_TITLE);
  const summary = str(b.summary).slice(0, MAX_SUMMARY);
  const reportText = str(b.report_text);
  if (!fingerprint || fingerprint.length > 200) return "bad fingerprint";
  if (!title) return "missing title";
  if (!reportText) return "missing report";
  const contact = str(b.contact).trim();
  if (contact && (contact.length > 254 || !EMAIL_RE.test(contact))) {
    return "bad contact";
  }
  const labels = (Array.isArray(b.labels) ? b.labels : [])
    .filter((l) => typeof l === "string")
    .map((l) => l.toLowerCase().replace(/[^a-z0-9._-]/g, "").slice(0, 40))
    .filter((l) => l.length > 0)
    .slice(0, MAX_LABELS);
  return { fingerprint, title, summary, reportText, labels, contact };
}

async function fileReport(env, r) {
  const id = randomId();
  const now = new Date();
  const yyyy = now.getUTCFullYear();
  const mm = String(now.getUTCMonth() + 1).padStart(2, "0");
  const path = `reports/${yyyy}/${mm}/${id}.txt`;

  const file = await gh(env, "PUT", `/contents/${path}`, {
    message: `Report ${id}: ${r.title}`,
    content: base64Utf8(r.reportText),
  });
  const fileUrl = file.content && file.content.html_url;

  const fpLabel = "fp-" + (await sha256Hex(r.fingerprint)).slice(0, 12);
  const text = [
    `**Report ${id}**${fileUrl ? ` · [full report](${fileUrl})` : ""}`,
    // In backticks: copyable as is, and GitHub never treats it as a mention.
    ...(r.contact ? ["", `Contact: \`${r.contact}\``] : []),
    "",
    codeBlock(r.summary),
  ].join("\n");

  // index/<fp>.json maps a fingerprint to its issue. GitHub's label filter
  // lags a few seconds behind a new issue; a file reads back at once.
  const indexPath = `/contents/index/${fpLabel}.json`;
  const index = await gh(env, "GET", indexPath, undefined, { allow404: true });
  let issueNumber = null;
  if (index) {
    const known = JSON.parse(atob(index.content.replace(/\n/g, ""))).issue;
    const issue = await gh(env, "GET", `/issues/${known}`, undefined, {
      allow404: true,
    });
    if (issue && issue.state === "open") issueNumber = known;
  }

  if (issueNumber) {
    await gh(env, "POST", `/issues/${issueNumber}/comments`, { body: text });
    if (r.contact) {
      await gh(env, "POST", `/issues/${issueNumber}/labels`, {
        labels: [CONTACT_LABEL],
      });
    }
  } else {
    const issue = await gh(env, "POST", "/issues", {
      title: r.title,
      body: `${text}\n\n<sub>fingerprint: \`${plainToken(r.fingerprint)}\`</sub>`,
      labels: [...r.labels, fpLabel, ...(r.contact ? [CONTACT_LABEL] : [])],
    });
    await gh(env, "PUT", indexPath, {
      message: `Index ${fpLabel} → #${issue.number}`,
      content: base64Utf8(JSON.stringify({ issue: issue.number })),
      ...(index ? { sha: index.sha } : {}),
    });
  }
  return id;
}

/** Cached release list of env.RELEASES_REPO (see the header comment). */
async function releases(request, env) {
  const cached = await cachedReleases(env);
  if (!cached) return json({ error: "releases unavailable" }, 502);
  const etag = cached.headers.get("etag");
  const headers = {
    "content-type": "application/json; charset=utf-8",
    "cache-control": `public, max-age=${RELEASES_FRESH_SEC}`,
    ...(etag ? { etag } : {}),
  };
  if (etag && request.headers.get("if-none-match") === etag) {
    return new Response(null, { status: 304, headers });
  }
  return new Response(cached.body, { headers });
}

/** Newest pump firmware for a board (see the header comment). */
async function pumpLatest(url, env) {
  const hw = Number(url.searchParams.get("hw"));
  const proto = Number(url.searchParams.get("proto"));
  if (!Number.isInteger(hw) || hw < 1 || hw > 255) {
    return json({ error: "bad hw" }, 400);
  }
  if (!Number.isInteger(proto) || proto < 0 || proto > 255) {
    return json({ error: "bad proto" }, 400);
  }
  const list = await cachedReleases(env);
  if (!list) return json({ error: "releases unavailable" }, 502);

  // The answer is cached against the release list it was made from, so it is
  // refreshed together with the list (including by /v1/refresh), never later.
  const stamp = list.headers.get("x-fetched-at") || "0";
  const cache = caches.default;
  const key = new Request(
    `https://cache.tanklink/pump-latest/${env.RELEASES_REPO}/${hw}/${proto}/${stamp}`,
  );
  const hit = await cache.match(key);
  if (hit) return answerLatest(await hit.json(), url);

  let latest;
  try {
    latest = await findPumpLatest(await list.json(), hw, proto);
  } catch (e) {
    console.error("pump latest failed", e && e.message);
    return json({ error: "releases unavailable" }, 502);
  }
  if (!latest) return json({ error: "no firmware" }, 404);
  await cache.put(
    key,
    new Response(JSON.stringify(latest), {
      headers: { ...jsonHeaders(), "cache-control": `max-age=${RELEASES_KEEP_SEC}` },
    }),
  );
  return answerLatest(latest, url);
}

/** The cached answer, with the download address on this host. */
function answerLatest(latest, url) {
  const out = {
    version: latest.version,
    url: `${url.origin}/v1/firmware/pump/download/${latest.version}.bin`,
    size: latest.size,
    sha256: latest.sha256,
  };
  return new Response(JSON.stringify(out), { headers: jsonHeaders() });
}

/** Stream a pump release's binary from GitHub (see the header comment). */
async function pumpDownload(version, env) {
  const cached = await cachedReleases(env);
  if (!cached) return json({ error: "releases unavailable" }, 502);
  const rel = (await cached.json()).find(
    (r) => !r.draft && !r.prerelease && r.tag_name === `pump-v${version}`,
  );
  const bin = rel && (rel.assets || []).find((a) => a.name === "pump_node.bin");
  if (!bin) return json({ error: "no such release" }, 404);
  const res = await fetch(bin.browser_download_url, {
    headers: { "user-agent": "tanklink-report-worker" },
  });
  if (!res.ok || !res.body) return json({ error: "download failed" }, 502);
  const headers = {
    "content-type": "application/octet-stream",
    // A release never changes, so this can be cached hard.
    "cache-control": "public, max-age=86400, immutable",
  };
  const len = res.headers.get("content-length");
  if (len) headers["content-length"] = len;
  return new Response(res.body, { headers });
}

function jsonHeaders() {
  return {
    "content-type": "application/json; charset=utf-8",
    "cache-control": `public, max-age=${RELEASES_FRESH_SEC}`,
  };
}

async function findPumpLatest(releases, hw, proto) {
  const found = [];
  for (const r of releases) {
    if (r.draft || r.prerelease) continue;
    const m = /^pump-v(\d+)\.(\d+)\.(\d+)$/.exec(r.tag_name || "");
    const bin = (r.assets || []).find((a) => a.name === "pump_node.bin");
    const man = (r.assets || []).find((a) => a.name === "firmware-manifest.json");
    if (!m || !bin || !man) continue;
    found.push({
      v: [Number(m[1]), Number(m[2]), Number(m[3])],
      bin,
      man,
    });
  }
  found.sort((a, b) => (newer(a.v, b.v) ? -1 : newer(b.v, a.v) ? 1 : 0));
  // Newest first; the first whose manifest fits this board wins.
  for (const c of found) {
    const res = await fetch(c.man.browser_download_url, {
      headers: { "user-agent": "tanklink-report-worker" },
    });
    if (!res.ok) continue;
    let man;
    try {
      man = await res.json();
    } catch {
      continue;
    }
    const sha = typeof man.sha256 === "string" ? man.sha256.toLowerCase() : "";
    if (!/^[0-9a-f]{64}$/.test(sha)) continue;
    if (man.proto_major !== proto) continue;
    if (!Array.isArray(man.hw_revs) || !man.hw_revs.includes(hw)) continue;
    return {
      version: c.v.join("."),
      url: c.bin.browser_download_url,
      size: c.bin.size,
      sha256: sha,
    };
  }
  return null;
}

/** 302 to the newest app release's APK (see the header comment). */
async function appDownload(env) {
  let target = APP_FALLBACK_URL;
  try {
    const cached = await cachedReleases(env);
    if (cached) {
      let best = null;
      for (const r of await cached.json()) {
        if (r.draft || r.prerelease) continue;
        const m = /^app-v(\d+)\.(\d+)\.(\d+)$/.exec(r.tag_name || "");
        const apk = (r.assets || []).find((a) => a.name === "TankLink.apk");
        if (!m || !apk) continue;
        const v = [Number(m[1]), Number(m[2]), Number(m[3])];
        if (!best || newer(v, best.v)) best = { v, url: apk.browser_download_url };
      }
      if (best) target = best.url;
    }
  } catch (e) {
    console.error("app redirect failed", e && e.message);
  }
  return new Response(null, {
    status: 302,
    headers: { location: target, "cache-control": "no-store" },
  });
}

function newer(a, b) {
  for (let i = 0; i < 3; i++) if (a[i] !== b[i]) return a[i] > b[i];
  return false;
}

/** One cache entry for the list, whatever query the app sends: this is not a proxy. */
function releasesKey(env) {
  return new Request(`https://cache.tanklink/releases/${env.RELEASES_REPO}`);
}

/** Forget the cached release list, fetch it again, and say what is newest. */
async function refreshReleases(env) {
  await caches.default.delete(releasesKey(env));
  const list = await cachedReleases(env);
  if (!list) return json({ error: "GitHub could not be reached" }, 502);
  const releases = await list.json();
  const newest = {};
  for (const r of releases) {
    const m = /^(app|pump|tank)-v(\d+)\.(\d+)\.(\d+)$/.exec(r.tag_name || "");
    if (!m || r.draft || r.prerelease) continue;
    const v = [Number(m[2]), Number(m[3]), Number(m[4])];
    if (!newest[m[1]] || newer(v, newest[m[1]].v)) newest[m[1]] = { v, tag: r.tag_name };
  }
  return json({
    ok: true,
    releases: releases.length,
    newest: Object.fromEntries(Object.entries(newest).map(([k, x]) => [k, x.tag])),
  });
}

/** Constant-time equality of two secrets (compares their hashes). */
async function sameSecret(a, b) {
  const enc = new TextEncoder();
  const [x, y] = await Promise.all([
    crypto.subtle.digest("SHA-256", enc.encode(a)),
    crypto.subtle.digest("SHA-256", enc.encode(b)),
  ]);
  const ax = new Uint8Array(x);
  const by = new Uint8Array(y);
  let diff = 0;
  for (let i = 0; i < ax.length; i++) diff |= ax[i] ^ by[i];
  return diff === 0;
}

/** The cached list as a Response (refreshed when stale), or null. */
async function cachedReleases(env) {
  const cache = caches.default;
  const key = releasesKey(env);
  let cached = await cache.match(key);
  const fetchedAt = Number(cached?.headers.get("x-fetched-at") || 0);
  const fresh = cached && Date.now() - fetchedAt < RELEASES_FRESH_SEC * 1000;

  if (!fresh) {
    try {
      const res = await fetch(
        `${GH_API}/repos/${env.RELEASES_REPO}/releases?per_page=${RELEASES_PER_PAGE}`,
        {
          headers: {
            authorization: `Bearer ${env.GITHUB_TOKEN}`,
            accept: "application/vnd.github+json",
            "x-github-api-version": "2022-11-28",
            "user-agent": "tanklink-report-worker",
          },
        },
      );
      if (!res.ok) throw new Error(`GitHub releases → ${res.status}`);
      const body = await res.text();
      cached = new Response(body, {
        headers: {
          "content-type": "application/json; charset=utf-8",
          etag: res.headers.get("etag") || "",
          "x-fetched-at": String(Date.now()),
          "cache-control": `max-age=${RELEASES_KEEP_SEC}`,
        },
      });
      await cache.put(key, cached.clone());
    } catch (e) {
      console.error("releases refresh failed", e && e.message);
      // Fall through to the older copy, if any.
    }
  }
  return cached || null;
}

async function gh(env, method, path, body, { allow404 = false } = {}) {
  const res = await fetch(`${GH_API}/repos/${env.GITHUB_REPO}${path}`, {
    method,
    headers: {
      authorization: `Bearer ${env.GITHUB_TOKEN}`,
      accept: "application/vnd.github+json",
      "x-github-api-version": "2022-11-28",
      "user-agent": "tanklink-report-worker",
      ...(body ? { "content-type": "application/json" } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (allow404 && res.status === 404) return null;
  if (!res.ok) {
    const detail = (await res.text()).slice(0, 300);
    throw new Error(`GitHub ${method} ${path} → ${res.status}: ${detail}`);
  }
  return res.json();
}

/**
 * User text as a fenced code block: GitHub renders nothing inside it, so no
 * links, images, HTML or @mentions. The fence is longer than any run of
 * tildes in the text, so the text can't close it.
 */
function codeBlock(s) {
  const longest = Math.max(0, ...(s.match(/~+/g) || []).map((m) => m.length));
  const fence = "~".repeat(Math.max(3, longest + 1));
  return `${fence}text\n${s}\n${fence}`;
}

/** Only characters that are safe inside inline code and HTML. */
function plainToken(s) {
  return s.replace(/[^A-Za-z0-9._:/-]/g, "_").slice(0, 200);
}

function oneLine(s) {
  return s.replace(/\s+/g, " ").trim();
}

/** 6 chars from an alphabet without look-alikes (no 0/O, 1/I/L). */
function randomId() {
  const alphabet = "23456789ABCDEFGHJKMNPQRSTUVWXYZ";
  const bytes = crypto.getRandomValues(new Uint8Array(6));
  return Array.from(bytes, (b) => alphabet[b % alphabet.length]).join("");
}

function base64Utf8(s) {
  const bytes = new TextEncoder().encode(s);
  let bin = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(bin);
}

async function sha256Hex(s) {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(s),
  );
  return Array.from(new Uint8Array(digest), (b) =>
    b.toString(16).padStart(2, "0"),
  ).join("");
}

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json" },
  });
}
