# Google OAuth verification: BumpCast (Gmail read-only)

Ready-to-paste answers for Google's restricted-scope review. Prepared Oct 27, 2026.

**Status (Oct 27, 2026):** submitted. Branding is verified and published. The app is published (In production), and Gmail data access is **under review**. The video is at https://www.youtube.com/watch?v=egHNs0zpYk8 (unlisted). Feature chosen: "Email productivity". Questionnaire: No to personal, internal, dev/testing and WordPress SMTP. Lanre ticked the acknowledgement that restricted scopes require a CASA assessment, recertified yearly. The notes field asks Google to confirm that an on-device app is out of scope. Plan for CASA anyway, and watch lanre@akinyemi.ca for Google's replies.

| | |
|---|---|
| Google Cloud project | `bumpcast` (organization akinyemi.ca), owner lanre@akinyemi.ca |
| App name on consent screen | BumpCast |
| User support email | support@akinyemi.ca |
| Developer contact | lanre@akinyemi.ca |
| Home page | https://bumpcast.app/ |
| Privacy policy | https://bumpcast.app/privacy.html (see "Connected email" and the Limited Use statement) |
| Terms of service | https://bumpcast.app/terms.html |
| Email access explainer | https://bumpcast.app/email.html |
| Authorized domain | bumpcast.app (verified in Search Console as lanre@akinyemi.ca) |
| OAuth client | iOS, bundle `ca.akinyemi.bumpcast`, App Store ID 6824269447, Team 2Q87Z7RM4V. Client ID `206714483669-4ih92bvj4iamuhvnln58u329mbv2pi8r.apps.googleusercontent.com` |
| Logo (120×120) | `bumpcast-logo-120.png` in this folder |
| Publisher | Akinyemi & Co Ltd |

## Scopes requested

| Scope | Type | Why |
|---|---|---|
| `https://www.googleapis.com/auth/gmail.readonly` | Restricted | Read flight booking confirmations to add the user's upcoming flights |
| `openid` | Non-sensitive | Sign-in |
| `https://www.googleapis.com/auth/userinfo.email` | Non-sensitive | Show which Gmail account is connected, in Settings, on the phone only |

No other Google scopes. BumpCast never sends, deletes, modifies or labels email.

## Scope justification (paste into "How will the scopes be used?")

> BumpCast is an iPhone flight tracker for nervous flyers. It forecasts turbulence and tracks the status of the user's upcoming flights. With BumpCast Pro, the user can choose to connect Gmail so the app adds their booked flights automatically, instead of typing flight numbers.
>
> When the user connects Gmail, the app runs a narrow Gmail search for likely booking emails from the past year: airline and travel-agency confirmations, itineraries and e-tickets, excluding spam, trash and promotions. It reads those messages on the user's iPhone and extracts only the flight number, departure date and airports. Each one is checked against public flight schedules and added to the user's flights. Later emails about the same booking (schedule changes, rebookings, cancellations) update that flight, with Undo.
>
> gmail.readonly is required because the flight details are in the message body. No narrower Gmail scope (gmail.metadata, labels) exposes message content, and we never need write access.
>
> All Gmail data is processed on the user's device. Message content is never transmitted to or stored on our servers or any third party. The OAuth tokens stay in the iOS Keychain on the device. The only thing that leaves the phone is the extracted flight number and date, sent to our server to look the flight up, exactly as when a user types a flight number. Names, booking references, addresses, loyalty numbers and payment details are ignored and never stored. The phone keeps only the IDs of messages already checked, so nothing is read twice. Users can disconnect at any time in Settings → Email, which revokes the token and deletes local data.
>
> Gmail data is not used for advertising, profiling, selling, human reading, or training AI/ML models. Our use complies with the Google API Services User Data Policy, including the Limited Use requirements, as stated in our privacy policy.

## Security assessment (CASA)

The case for being out of scope: Google requires a security assessment for apps that **store or transmit restricted-scope data on servers**. BumpCast does neither, because Gmail content is read only on the device. Say so in the submission's notes field and ask Google to confirm:

> BumpCast is a native iOS app with no server-side access to Gmail. Restricted-scope data is accessed and processed solely on the user's device; no Gmail data, tokens or derived message content are transmitted to or stored on any server. We believe the app is therefore out of scope for the CASA security assessment. Please confirm.

If Google still asks for CASA, the lab, tier and cost need Lanre's decision.

## Demo video (unlisted YouTube, about 2 minutes, English)

**Recorded Oct 27:** `bumpcast-gmail-demo.mp4` in this folder (70 s, 1206×2622). A caption across the top shows the app, the scope and the OAuth client ID throughout. It covers the explanation sheet, Google's account chooser and consent screen ("View your email messages and settings"), the first scan with progress, "We added 1 flight", the added flight, and Settings → Email → Disconnect. Upload it to YouTube as **Unlisted** and paste the link into the submission. It's 42 MB, so don't commit it to git.

Google's checklist: show the full OAuth flow with the **consent screen in English**, the **app name** as on the consent screen, the **scopes** being granted, and **how each scope's data is used** in the app. If you can, show the **OAuth client ID** in the browser address bar of the consent screen. iOS's sign-in sheet shows only the domain, so add a caption, or record the client ID from the Cloud console in the same video, as below.

Shot list (recorded on the iOS simulator, as a Pro test user):
1. **0:00** Title card or caption: "BumpCast · Gmail read-only · Client ID 206714483669-4ih92bvj4iamuhvnln58u329mbv2pi8r". Optionally cut to Google Cloud console → Clients, showing the same ID.
2. **0:10** Open BumpCast → **Add flight** → **Add from your email**. Show the explanation sheet with the four lines (only flight bookings, remove any flight, read on this iPhone, disconnect any time).
3. **0:25** Tap **Connect Gmail** → iOS "wants to use google.com to sign in" → **Continue**.
4. **0:35** Google sign-in → consent screen: app name **BumpCast**, "View your email messages and settings" (gmail.readonly), the email address scope → **Continue / Allow**.
5. **0:55** Back in the app: first-scan progress ("Checked X of Y booking emails"), then **"We added N flights"**, showing the flights extracted (number, date, route).
6. **1:15** Open one added flight: its route, times and forecast, which is how the data is used.
7. **1:30** **Settings → Email**: connected account, Last checked, Check now. Tap **Disconnect** → confirm. Show that the account is gone.
8. **1:45** Optional: Google Account → Security → Third-party connections, showing BumpCast removed.

Use a mailbox with a real or test airline confirmation, and blur names and booking references if any appear.

## Steps in Google Cloud console (Lanre)

1. **Branding → App logo**: upload `bumpcast-logo-120.png`. This starts brand verification, usually a few business days.
2. **Audience → Publish app**: moves the app from Testing to In production. Unverified users then see the "unverified app" screen until approval; test users keep working.
3. **Verification Center → Prepare for verification**: confirm the branding, paste the scope justification above, add the YouTube link, and paste the CASA note in "Additional info". Submit.
4. Watch lanre@akinyemi.ca for Google's emails and answer follow-ups within a few days. Each round adds time.

## Before the feature ships

- Until Gmail is verified, only test users (up to 100) can connect. Ship 1.0.3 with the email row hidden, or hold the feature (open in `docs/release/1.0.3.md`).
- The App Store listing's privacy and support URLs still point at the Google Docs. Switch them to https://bumpcast.app/privacy.html and /support.html so they match what Google reviews.
- App Privacy labels: no change, because email is processed only on the device.
