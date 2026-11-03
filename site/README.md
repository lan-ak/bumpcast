# BumpCast website

Static pages for the App Store listing and for Google's and Microsoft's OAuth reviews (Gmail and Outlook import, `docs/release/EMAIL_IMPORT_SETUP.md`). Domain not chosen yet: every link is relative, so the folder works on any domain.

Preview locally: the `site` entry in `.claude/launch.json` (`python3 -m http.server 4173 --directory site`).

## Pages and what they satisfy

| Path | For |
|---|---|
| `/` | Google home page: same app name as the consent screen ("BumpCast"), describes the app and why it reads email, links the privacy policy, no login. Microsoft home page URL |
| `/privacy.html` | App Store privacy URL. Google privacy policy, including the required Limited Use sentence, what email data is read, kept, shared, and how to revoke. Microsoft privacy statement URL |
| `/email.html` | Plain-language explainer of email access (scopes, what leaves the phone, revoke). Linked from the consent flow and the Google submission |
| `/terms.html` | Google and Microsoft terms of service URL. Supplements Apple's standard EULA |
| `/support.html` | App Store support URL |
| `/.well-known/microsoft-identity-association.json` | Microsoft publisher-domain verification. **Replace the zero GUID with the Entra app's Application (client) ID** before deploying |
| `/llms.txt` | Plain Markdown summary of the app and its key features for AI agents and LLM crawlers ([llms.txt](https://llmstxt.org) convention). Keep in step with the App Store description |
| `/404.html` | Host not-found page (root-relative links, so it works at any depth) |

Look: the app's "Cabin Dawn" mood layer (docs/design/DESIGN_SPEC.md). `sky.js` picks a dawn, day, dusk or night sky from the visitor's clock (dark mode is always night), with glass cards, the wave timeline, water-glass severity glyphs and the breathing orb. No cookies, analytics, third-party scripts or fonts. Fonts are the app's own OFL fonts in `fonts/`.

Publisher: Akinyemi & Co Ltd (in the footer, privacy policy and terms).

## Live at https://bumpcast.app

- Domain: `bumpcast.app`, registered at Namecheap on Oct 27, 2026 by Akinyemi & Co Ltd. Renews Oct 27, 2027.
- Hosting: GitHub Pages on the `gh-pages` branch of `lan-ak/bumpcast`, with custom domain `bumpcast.app`. `CNAME` is in this folder.
- DNS at Namecheap (Advanced DNS):
  - `A @` → 185.199.108.153, 185.199.109.153, 185.199.110.153, 185.199.111.153
  - (Optional, not set) `AAAA @` → 2606:50c0:8000::153 … 8003::153 for IPv6
  - `CNAME www` → `lan-ak.github.io.`
  - Set on Oct 27, 2026. Namecheap's parking `CNAME www` and URL redirect were removed. Its email-forwarding TXT (SPF) record was left alone.

### Publishing a change

`gh-pages` holds only the built files, with no history worth keeping. From the repo root:

```bash
scripts/publish_site.sh
```

It copies `site/` (minus this README) into a temporary checkout of `gh-pages`, commits and pushes. Pages redeploys in about a minute.

### Still to do

1. Done (Oct 27): HTTPS certificate issued and **Enforce HTTPS** on. If it ever stalls, remove and re-add the custom domain to re-trigger it.
2. Verify `bumpcast.app` for GitHub Pages (Settings → Pages → Verified domains, a TXT record). This stops anyone else claiming the domain on GitHub.
3. Done (Oct 27): verified in Google Search Console as lanre@akinyemi.ca (TXT record in Namecheap; keep it).
4. Point the App Store privacy and support URLs at `https://bumpcast.app/privacy.html` and `/support.html` (`metadata/`, `asc metadata push`).
5. Replace the zero GUID in `.well-known/microsoft-identity-association.json` with the Entra client ID once registered.
