# Email import: domain and verification runbook (E1)

Decision (Oct 18): build **E1** from `BOOKING_IMPORT.md`. It scans the user's Gmail or Outlook **on the phone** for future flights and adds them automatically, with Undo. Google's restricted-scope review is the slowest step, so it starts before any code.

**Status (Oct 27):** bumpcast.app is bought (Namecheap), live on GitHub Pages over HTTPS and verified in Search Console. The Google Cloud project `bumpcast` has the consent screen (Testing), the Gmail read-only scope and the iOS client. Microsoft is deferred: Outlook stays hidden. Not yet submitted to Google; the submission pack is in `google-verification/GOOGLE_VERIFICATION.md`. Steps marked **Lanre** need his accounts, payment or signature. Steps marked **Claude** can be done in the repo.

## 0. Pick the domain (Lanre)

Google needs the home page and privacy policy on a domain the project owner has verified in Search Console. Microsoft publisher verification needs a domain that matches the Partner Center account's email domain.

| Option | Google | Microsoft | Cost and setup | Notes |
|---|---|---|---|---|
| **`bumpcast.akinyemi.ca`** (subdomain of the domain you already own) | Verify `akinyemi.ca` once in Search Console. It's already on Google Workspace (`lanre@akinyemi.ca`), so this is quick | Matches your Partner Center email domain (`akinyemi.ca`) with no extra mailbox | Free. One CNAME at GoDaddy (`akinyemi.ca` uses GoDaddy DNS) | Fastest. The consent screen links a less branded URL. Works for Cribbage Nights later too |
| **`bumpcast.app`** (looked unregistered on Oct 18: no NS records) | Verify `bumpcast.app` in Search Console | Needs a Partner Center contact email **at** `bumpcast.app` (e.g. `support@bumpcast.app` as a Workspace alias domain), or verify under `akinyemi.ca` instead | About $15/yr. `.app` forces HTTPS, which any modern host handles | Best brand. Also the natural home for a future forwarding address (option D) |
| `getbumpcast.com` (free on Oct 18) | Same as above | Same as above | About $12/yr | Fallback if `.app` is taken. `bumpcast.com` is registered to someone else (GoDaddy, since 2013) |

**Recommendation:** buy `bumpcast.app` for the public site and App Store links. Use **`akinyemi.ca` as the publisher domain** for Microsoft, and add it as a second authorized domain for Google, so neither review waits on a new mailbox. If speed matters more than brand, use `bumpcast.akinyemi.ca` and skip the purchase.

## 1. Put the site on the domain (Claude prepares, Lanre deploys)

**Done locally (Oct 18):** `site/` is committed with home, privacy (connected-email section and Limited Use), email access, terms, support, 404 and the Microsoft `.well-known` file. Every link is relative, so it works on any domain. See `site/README.md` for what each page satisfies and how to deploy. Still to do: pick and buy the domain, add the Entra client ID to the `.well-known` file, and deploy.

- `site/` is in the main checkout but **not committed**. Commit it, then host it as static files. GitHub Pages or Cloudflare Pages are both free and handle HTTPS.
- The pages Google checks:
  - **Home page** (`/`): names the app exactly as on the consent screen ("BumpCast"), says what it does, and links the privacy policy. It must not be a login page. `site/index.html` already does this.
  - **Privacy policy** (`/privacy.html`): needs the new "Connected email" section below **before** submitting.
  - Optional for Microsoft but cleaner: `/.well-known/microsoft-identity-association.json` with the app's client ID. That lets the publisher domain be the site's own domain.
- Point the App Store listing's privacy and support URLs at the new site once it's live (`asc metadata push`). Then the Google Docs pages can retire.

### New privacy policy section (draft for `site/privacy.html` and the Google Doc)

> **Connected email (optional)**
> If you connect Gmail or Outlook, BumpCast looks for flight bookings in your email so it can add your upcoming flights for you. This happens on your iPhone. Your emails are never sent to our servers or stored by us, and they aren't shared with anyone.
> From each booking we keep only what we need to forecast the flight: the flight number, date and airports. These are saved like any flight you add yourself.
> BumpCast asks for read-only access and never sends, deletes or changes your email. You can disconnect at any time in Settings → Email. That removes BumpCast's access, and the flights already added stay unless you delete them.
> BumpCast's use and transfer of information received from Google APIs will adhere to the [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy), including the Limited Use requirements.

The last sentence is the Limited Use disclosure Google requires word for word. Also add "Google (if you connect Gmail)" and "Microsoft (if you connect Outlook)" to *Service providers*. Here they're named because that's the user's own account. In the app, the design rule only covers forecast and flight data sources.

## 2. Google Cloud project and consent screen (Lanre, in Google Cloud Console)

1. Create the project **BumpCast** under `lanre@akinyemi.ca`.
2. **Google Auth Platform → Branding:**
   - App name `BumpCast` and the app icon.
   - Support email `support@akinyemi.ca`.
   - Home page, privacy policy and terms URLs on the new domain.
   - Authorized domains: the new domain, plus `akinyemi.ca` if used.
   - Developer contact `lanre@akinyemi.ca`.
3. **Audience:** External, in **Testing** at first. Add test users (up to 100), so E1 can be built and tried before approval.
4. **Data access → scopes:** `https://www.googleapis.com/auth/gmail.readonly` only (restricted), plus `openid` and `email`, so Settings can show which account is connected. Ask for nothing else.
5. **Clients → Create OAuth client → iOS**, bundle ID `ca.akinyemi.bumpcast`.
   - Google gives a client ID and the reversed-client-ID URL scheme (`com.googleusercontent.apps.<id>`). The app uses that scheme as the redirect with `ASWebAuthenticationSession` and PKCE. No client secret and no Google SDK.
   - The client ID goes in `ios/Config/Secrets.xcconfig` like the other keys.
6. In Search Console, verify the authorized domains **with the same Google account** that owns the project.

### Submitting for restricted-scope verification (after E1 works in Testing)

Google needs a working build to review, so submit once the scan works for test users. Expect several weeks; Google's review emails go to the developer contact.

- **Scope justification (draft):**
  > BumpCast forecasts turbulence for a traveller's upcoming flights. With the user's permission, it searches their Gmail for airline and travel-agency booking confirmations and reads them on the user's iPhone to find the flight number, date and airports, then adds those flights automatically. Read-only access is required because booking details are in the message body. No narrower scope exposes them. Email content is processed only on the device and is never transmitted to or stored on our servers. Only the extracted flight number, date and airports are saved.
- **Demo video** (unlisted YouTube, about 2 minutes), shot in English with the OAuth client ID visible in the URL bar of the consent screen:
  1. Open BumpCast, tap **Find flights in your email**, then **Connect Gmail**.
  2. Show Google's consent screen with the app name and the `gmail.readonly` scope.
  3. Show the flights appear with the "Added from your email" eyebrow, and open one.
  4. Show Settings → Email → **Disconnect**.
- **Security assessment:** Google's restricted-scope page requires a yearly third-party assessment (CASA) for apps that **store or transmit restricted data on servers**. E1 does neither. The listed exceptions don't name on-device apps explicitly, so **state the on-device design in the submission and ask Google to confirm** that no assessment is needed. If Google says otherwise, budget for a CASA Tier 2 assessment before launch.

## 3. Microsoft app registration (Lanre, in the Microsoft Entra admin center)

1. Sign in with a Microsoft account. If there's no Entra tenant yet, a free one is created with it.
2. **App registrations → New registration:**
   - Name `BumpCast`.
   - Supported accounts: **any organizational directory and personal Microsoft accounts**.
   - Redirect URI: **Public client / native (mobile & desktop)** `msauth.ca.akinyemi.bumpcast://auth`.
3. **Authentication:** allow public client flows. There's no client secret: it's a native app using PKCE.
4. **API permissions:** Microsoft Graph, delegated:
   - `Mail.Read`, `offline_access`, `User.Read`, `openid`, `email`.
   - No admin consent is needed for personal accounts. Some work tenants block user consent, and those users get "Need admin approval"; that's acceptable.
5. **Branding & properties:** home page, privacy and terms URLs on the new domain, and the logo.
6. **Publisher verification** (removes "unverified" from the consent prompt; work tenants often require it):
   - Join the Microsoft AI Cloud Partner Program (free) to get a **Partner One ID**, from the partner global account, not a location ID.
   - Verify the publisher domain. Either DNS-verify `akinyemi.ca` in the tenant (it matches your Partner Center email), or host the `.well-known` file.
   - Then **Branding & properties → Add Partner One ID**.
   - Company verification in Partner Center can take a few days. Personal accounts can consent before it's done.
7. Add the client ID to `ios/Config/Secrets.xcconfig`.

## 4. Apple (Claude, at build time)

- Info.plist: URL schemes for the Google reversed client ID and `msauth.ca.akinyemi.bumpcast`. Background task identifier for `BGAppRefreshTask`.
- No new permission prompt and **no App Privacy label change**: email is read on the phone, and the extracted flights are already declared under Other User Content. Update the privacy doc and App Review notes ("Connect Gmail" demo account, with test users added in Google Testing).
- If E1 ever moves to the server (E2), the label gains *Emails or Text Messages*, and Google's assessment becomes mandatory.

## 5. "Coming soon" until Google verifies (from 1.0.3)

Lanre's call, Oct 27: email import is hidden until it's ready, and the app just says it's coming soon. The code ships in 1.0.3 but does nothing for users.

**The switch:** `EmailImport.isReady` in `ios/BumpCast/Services/EmailImport.swift`.
- **Release builds (TestFlight and the App Store): off.**
- **Debug builds: on**, so the feature can still be built and tested from Xcode. Launch with `-emailImportComingSoon` to see what Release builds show.

**What people see while it's off:**
- **Add a flight, "Other ways to add":** an "Add from your email" row with the subtitle "Coming soon". It has no chevron, and tapping does nothing.
- **Settings › Email:** one row, "Add flights from your email", reading "Coming soon". Nothing can be tapped: no Connect, Check now or Disconnect.

**What doesn't happen while it's off:**
- `connect`, `scan` and `scanIfDue` return straight away. Nothing signs in to Gmail, and the foreground and background scans don't run, even on a phone that connected in a Debug build.
- The `email_import_locked` paywall never opens. The Pro paywall only lists the email benefit when that placement opened it, so no other paywall mentions email.
- Flights and notes already imported on a test phone stay as they are. On real users' phones there are none.

**Turning it on, once Google has verified the scope:**
1. Make `isReady` true in Release, so a later app version ships it.
2. Test the parts never tried on live data: the background scan, a full Undo of a change or cancellation, and Settings › Email while connected and Pro.
3. Update What's New and the App Review notes (a "Connect Gmail" demo account).

Turning it on needs an app update, because the switch is compiled in. A remote switch would remove that need, but it hasn't been built.

**Not affected:** `site/privacy.html` already describes email import. That's fine while it's coming soon, and Google's review needs the wording.

## Order of work

| # | Step | Who | Waits on |
|---|---|---|---|
| 1 | Pick the domain, buy it if needed, point DNS at the host | Lanre | Nothing |
| 2 | Commit `site/`, add the privacy section, set up hosting | Claude, then Lanre deploys | 1 |
| 3 | Google Cloud project, consent screen in Testing, iOS client, Search Console | Lanre | 2 (live URLs) |
| 4 | Entra app registration; start Partner Program enrolment | Lanre | 2 |
| 5 | Build E1 against Testing clients | Claude | 3, 4 client IDs |
| 6 | Submit Google verification (video and justification); finish Microsoft publisher verification | Lanre | 5 working build |
| 7 | Ship. Outlook can go first if Google's review is still pending | Lanre and Claude | 6 |
