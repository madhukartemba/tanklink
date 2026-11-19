# TankLink report service

A Cloudflare Worker at `https://tanklink-reports.madhukartemba.in` with two jobs.

## Release list for update checks (`GET /v1/releases`)

Every app's pump, tank and app update check asks here instead of GitHub. The Worker fetches the `madhukartemba/tanklink` release list (`RELEASES_REPO` in `wrangler.toml`) with `GITHUB_TOKEN` and keeps it for 10 minutes, so GitHub sees about 6 calls an hour however many phones there are. Without it, phones that share an internet connection share GitHub's limit of 60 calls an hour for apps that don't sign in.

- The response is GitHub's JSON as is, with GitHub's ETag; `If-None-Match` gets a 304.
- If GitHub fails, the last copy is served for up to a day.
- If the Worker can't be reached, the app asks GitHub directly (`releasesServiceUrl` in `tanklink_app/lib/update/github_release_util.dart`).
- A fine-grained token can read any public repo, so the reports token works here too.

## Problem reports (`POST /v1/report`)

Receives "Report a problem" submissions from the app and files them in a private GitHub repo:

- the full report is saved as `reports/YYYY/MM/<id>.txt`
- one issue per distinct problem; a report with the same fingerprint as an open issue adds a comment instead
- `index/fp-<hash>.json` maps each fingerprint to its issue. GitHub's label filter lags a few seconds behind a new issue, so grouping can't rely on it. Once that issue is closed, the next report opens a new one and the index points there.

The app only knows the URL (`ReportSender.endpoint` in `tanklink_app/lib/diag/report_sender.dart`) and the app key. The body format is a shared contract with that file.

## Set up (once)

1. Create a **private** repo, e.g. `tanklink-reports`, with a README so it has a default branch. Set `GITHUB_REPO` in `wrangler.toml` if the name differs.
2. Create a **fine-grained token** (GitHub → Settings → Developer settings → Fine-grained tokens), limited to that repo only, with:
   - Contents: Read and write
   - Issues: Read and write
3. Install Node.js, then in this folder:

   ```bash
   npm install
   npx wrangler login
   npx wrangler secret put GITHUB_TOKEN
   npx wrangler secret put APP_KEY
   ```

   `APP_KEY` is any long random string (`openssl rand -hex 24`). Put the same value in `ReportSender.appKey` in the app.
4. `routes` in `wrangler.toml` puts it on `tanklink-reports.madhukartemba.in` (the domain's DNS is on Cloudflare; deploy creates the record). Keep this URL: every installed app has it built in.
5. `npx wrangler deploy`. `ReportSender.endpoint` in the app is `https://tanklink-reports.madhukartemba.in/v1/report`.

## Try it

```bash
npx wrangler dev
```

Put `GITHUB_TOKEN` and `APP_KEY` in a `.dev.vars` file (gitignored) for local runs; point `GITHUB_REPO` at a throwaway repo while testing. Then:

```bash
curl -s localhost:8787/v1/report -H 'content-type: application/json' -d '{"app_key":"<key>","fingerprint":"test-1","title":"Test report","labels":["test"],"summary":"Hello","report_text":"Full report text"}'
```

Check: a new issue the first time, a comment on the same issue the second time, `401` with a wrong key, `413` for a body over 200 KB.

## Limits

- 200 KB per report, 5 reports a minute per IP (`[[ratelimits]]` in `wrangler.toml`).
- The app key can be pulled out of the APK. It only stops casual spam; rotate it with an app release if it gets abused.
- `@` in user text is defused so nobody gets pinged.
