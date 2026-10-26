# The Sky Report

Turbulence grades for 50 popular US and Canadian routes, for morning, afternoon and evening departures, today and tomorrow. One report feeds two things:

1. **Daily social cards** for TikTok, Reels and Shorts (`render_cards.py`).
2. **A page for every route** that answers "Will my flight from X to Y be bumpy?" for search and AI answers (`build_site.py`).

It publishes the grade only. When and how long the bumps last is what Pro sells, so it stays in the app. House rules apply: calm wording, no red, and data sources are never named.

## How it fits together

```
worker (Fly, hourly)  ──►  Supabase sky_reports (id 'latest', anon-readable)
                                    │
           ┌────────────────────────┴────────────────────────┐
           ▼                                                 ▼
render_cards.py → build/cards/<date>/              build_site.py → build/site/
  4 PNGs, sky-report.mp4, caption.txt                 site/ + /routes/<slug>/, sitemap.xml
```

- **Worker:** `worker/src/smooth_worker/skyreport.py` holds the route list and departure times. `smooth-worker run` rebuilds the report hourly on its own thread, so it never holds up notifications. It holds the weather lock for one departure at a time, so new flights never wait for the whole report. A failed route is left out. If every route fails, the last report is kept.
- **One-off:** `uv run --project worker smooth-worker sky-report --out report.json [--store]`.
- **Database:** migration `20261026000000_sky_reports.sql`. Run `supabase db push` before deploying the worker, or the hourly step logs an error each pass. That doesn't affect anything else.

## Make the cards (daily, evening Eastern)

```bash
export SUPABASE_URL=https://<project>.supabase.co SUPABASE_ANON_KEY=<public anon key>
python3 marketing/skyreport/render_cards.py
```

The output goes to `build/cards/<tomorrow>/`. Post `sky-report.mp4` or the four PNGs as a photo carousel, add a sound in the app, and paste `caption.txt`. It needs Chrome or Chromium (`CHROME=` to override the path) and ffmpeg.

- **When to post:** in the evening, so people see tomorrow's sky the night before they fly.
- **What to boost:** only posts that already did well organically (Spark Ads).

## Build the site (hourly)

```bash
python3 marketing/skyreport/build_site.py --base-url https://<your domain>
```

This writes `build/site/`, a complete static site: `site/` pages, `/routes/`, one page per route, `sitemap.xml` and `robots.txt`. It uses only the standard library.

- **Fonts:** come from `ios/Shared/Fonts`.
- **Accuracy:** the after-landing accuracy line appears once 50 or more flights are rated.
- **Old pages:** each page flags itself in the browser if it's more than 6 hours old, so a host that keeps serving it after rebuilds stop doesn't present it as current.

## Hosting: Google Cloud Run

The live site is `serve.py` on Cloud Run, not the static build. It renders the same pages from the latest report in Supabase and reloads every 5 minutes, so there's no build to schedule.

- **If Supabase can't be reached,** it keeps serving the last report.
- **A report older than 3 hours** is still served, with the page's "hasn't been updated" note shown.
- **The sample report** is refused unless `ALLOW_SAMPLE=1`.
- **Cost:** it scales to zero, so a small site stays inside Cloud Run's free tier. Pages are sent with `Cache-Control: max-age=300`.

### Deploy

First, one-time setup:

1. Install the gcloud CLI and run `gcloud auth login`.
2. Have a project with billing on. Cloud Run needs billing even inside the free tier.

Then deploy:

```bash
GCP_PROJECT=<project id> BASE_URL=https://<domain> \
SUPABASE_URL=https://<ref>.supabase.co SUPABASE_ANON_KEY=<public anon key> \
DOMAIN=<domain> marketing/skyreport/deploy_gcp.sh
```

The script:
- turns on Cloud Run, Cloud Build and Artifact Registry;
- uploads only `site/`, the fonts and the three server files;
- deploys the `bumpcast-site` service in `us-central1`;
- prints the service URL.

With `DOMAIN` set, it also maps the domain and prints the DNS records to add at your registrar.
- **Verify the domain first:** run `gcloud domains verify <domain>` once before mapping.
- **HTTPS:** the certificate is issued within about an hour of the DNS records going in.

Re-run the same command to ship changes.

**Leave `DOMAIN` off at first** and check `<service url>/routes/` against the live report before pointing a domain at it. `BASE_URL` should already be the final domain, because it's written into canonical links and the sitemap.

### After the domain is live

1. In Google Search Console, add the domain, then submit `https://<domain>/sitemap.xml`.
2. Use URL Inspection on `/routes/` and two or three route pages to ask for a first crawl.
3. Add `utm_source` to links from ads and social posts. Redirects keep the query string.

### Local preview

```bash
REPORT_FILE=marketing/skyreport/fixtures/sample-report.json ALLOW_SAMPLE=1 BASE_URL=http://localhost:8080 \
  python3 marketing/skyreport/serve.py
```

To test the image itself, build `Dockerfile` from the context `deploy_gcp.sh` assembles.

`build_site.py` still writes the same site as static files, for previews or a static host.

## Safety checks

`build_site.py` and `render_cards.py` refuse to run:
- on a report older than 3 hours (`--allow-stale` overrides);
- on the sample report (`--allow-sample` overrides).

The sample report has made-up weather and is only for previews:

```bash
uv run --project worker python marketing/skyreport/sample_report.py      # rewrites fixtures/sample-report.json
python3 marketing/skyreport/build_site.py marketing/skyreport/fixtures/sample-report.json \
  --allow-sample --allow-stale --base-url http://localhost:8000
python3 -m http.server 8000 -d build/site
python3 marketing/skyreport/render_cards.py marketing/skyreport/fixtures/sample-report.json --allow-sample --allow-stale
uv run --project worker pytest marketing/skyreport
```

## Changing routes

Edit `ROUTES` in `skyreport.py`. `worker/tests/test_skyreport.py` checks that every route stays inside coverage. Outside coverage, the route would show "Not available" everywhere.
