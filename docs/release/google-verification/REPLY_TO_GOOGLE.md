# Reply to Google: BumpCast (project 206714483669)

**Draft, Nov 9, 2026. Not sent.** Replaces nothing in the Oct 27 pack except the CASA note, which it corrects. The site is published. Before sending: wait for Apple's beta review so the TestFlight link works, and check the Cloud Console scopes match the three listed.

---

Hello,

Thank you for the checklist. We've audited BumpCast against it, changed the app and privacy policy where needed, and answer each section below.

**One correction to our submission.** Our notes said no derived message content is transmitted to a server. That was wrong, and we withdraw it. Gmail messages and OAuth tokens never leave the iPhone, but the flight details extracted from a booking (flight number, airline, dates, times and airports) are sent to our server to forecast the flight. Given that, please tell us whether a CASA assessment is required and at which tier, and we will complete it.

**Scopes.** We request `gmail.readonly`, `openid` and `userinfo.email`, and nothing else. `gmail.readonly` is the narrowest scope that exposes a message body, and flight details are only in the body. `gmail.metadata` doesn't expose it. The app never sends, changes or deletes email, so no change appears in the user's Gmail account.

**Production readiness and live users.** The feature is complete, but is switched off in our App Store build until verification finishes, as your Live Apps guidance asks. Unverified scopes are not exposed to production traffic.

**How to test it.** No login, payment or phone number is needed in this build, and paywalls are removed:

1. Install: https://testflight.apple.com/join/U9YhHZze
2. Open BumpCast and finish the short welcome questions.
3. Tap + (Add flight), then **Add from your email**, then **Connect Gmail**.
4. Sign in with any Gmail account holding an airline booking confirmation for a future flight, and allow access. The flight appears under "We added".
5. Settings → Email shows the connected account, Check now and Disconnect.

**Demo video:** https://www.youtube.com/watch?v=egHNs0zpYk8 (unlisted). It shows both consent screens, each scope in use, and Disconnect.

**Privacy policy:** https://bumpcast.app/privacy.html#email states the data accessed, how it's used, who receives it, how it's protected, and retention and deletion. Detail: https://bumpcast.app/email.html.

**Limited Use.** Gmail data and anything derived from it is used only to add and update the user's flights and forecast them. Flights found in email, and counts of them, are excluded from our product analytics and subscription tools, and aren't used for advertising or to choose offers. They go only to our server, our flight schedule provider (with no user information, to find the flight), and Apple (to deliver notifications about it). Nothing is sold or read by people.

**AI/ML.** BumpCast uses no AI or machine-learning models on Gmail data, and doesn't transfer it to any AI service.

**Prohibited use cases and Data Portability.** BumpCast has none of the listed uses and doesn't use Data Portability APIs.

BumpCast is not an integration platform.

Best regards,
Lanre Akinyemi
Akinyemi & Co Ltd
