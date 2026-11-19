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
 *
 * Response: 200 {"id": "K7Q2MX"} | 4xx/5xx {"error": "..."}
 */

const MAX_BODY_BYTES = 200 * 1024;
const MAX_TITLE = 120;
const MAX_SUMMARY = 4000;
const MAX_LABELS = 8;
const GH_API = "https://api.github.com";

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/health") {
      return json({ ok: true });
    }
    if (url.pathname !== "/v1/report") {
      return json({ error: "not found" }, 404);
    }
    if (request.method !== "POST") {
      return json({ error: "method not allowed" }, 405);
    }

    if (env.REPORT_LIMITER) {
      const ip = request.headers.get("cf-connecting-ip") || "unknown";
      const { success } = await env.REPORT_LIMITER.limit({ key: ip });
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
  const labels = (Array.isArray(b.labels) ? b.labels : [])
    .filter((l) => typeof l === "string")
    .map((l) => l.toLowerCase().replace(/[^a-z0-9._-]/g, "").slice(0, 40))
    .filter((l) => l.length > 0)
    .slice(0, MAX_LABELS);
  return { fingerprint, title, summary, reportText, labels };
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
    "",
    quote(r.summary),
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
  } else {
    const issue = await gh(env, "POST", "/issues", {
      title: r.title,
      body: `${text}\n\n<sub>fingerprint: ${escapeMentions(r.fingerprint)}</sub>`,
      labels: [...r.labels, fpLabel],
    });
    await gh(env, "PUT", indexPath, {
      message: `Index ${fpLabel} → #${issue.number}`,
      content: base64Utf8(JSON.stringify({ issue: issue.number })),
      ...(index ? { sha: index.sha } : {}),
    });
  }
  return id;
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

/** Markdown quote with @mentions defused so nobody gets pinged. */
function quote(s) {
  return escapeMentions(s)
    .split("\n")
    .map((l) => `> ${l}`)
    .join("\n");
}

function escapeMentions(s) {
  return s.replace(/@/g, "@​");
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
