# BumpCast on Trybe: program setup and creator briefs

The Trybe version of the Sideshift campaign (`docs/SIDESHIFT_CAMPAIGN.md`). Same product story and the same two briefs, but Trybe works differently, so the setup is different: **creators send BumpCast raw videos, and BumpCast runs them as Meta ads.** Creators don't run accounts for us. They get a small fee per approved video, plus a share of what BumpCast spends running their video as an ad. Sections marked **paste** go into Trybe as written.

## How Trybe differs from Sideshift (for you, not the creators)

| | Sideshift | Trybe |
|---|---|---|
| What creators deliver | Daily posts on TikTok and Instagram accounts BumpCast owns | Raw, clean videos uploaded to Trybe. BumpCast runs the approved ones as ads |
| Pay | $9 a day plus $2 per 1,000 views | CA$10 per approved video, plus 10% of the ad spend on that video |
| Rights | Sideshift contract: use in ads, no end date | Licensed once Trybe charges the fee. Because there's a commission, assume you lose the license if you stop paying it |
| Where ads run | Spark Ads and boosts on the creator accounts | Only through the Meta ad account connected to Trybe, tagged with the video's Trybe ID |
| Talking to creators | Sideshift inbox, plus Gmail logins | Trybe chat only. Trybe's terms ban moving creators off-platform for 12 months |

BumpCast's Trybe brand was created Oct 30: currency CAD, no programs or creators yet, one Meta ad account connected, no TikTok account. Trybe can't attribute sales for an app (no store connected), so a sales commission would pay nothing. Paying on ad spend works instead: the creators whose videos win get more, because you put more money behind them. The small flat fee is there so creators apply at all, since 10% of a small Meta budget is little on its own.

## Before you open the program

1. **Create the program in the Trybe dashboard.** The Trybe tools available here can review videos and message creators, but they can't create programs, so this step is yours. Settings:
   - **Name:** BumpCast: nervous flyers
   - **Payment:** two parts.
     - A flat fee of **CA$10** per approved submission. Flyers get up to 3 paid videos and talkers up to 2, so 6 creators cost at most CA$150 in fees to creators. Trybe charges your card when you approve each video, with no deposit.
     - A commission of **10% of ad spend** on each creator's videos. If about CA$300 of the Meta budget runs on Trybe videos, that's about CA$30 shared among the creators. Trybe bills commissions at least monthly. Trybe applies a raise straight away; a cut only reaches existing creators after 30 days, so start low at 10%.
     - **Trybe's fees:** 1.5% of flat fees and 1.25% of ad spend. Trybe says its fees never stack, so check in the dashboard which one it charges on a mixed program.
     - **Rights:** the terms only promise a perpetual license for flat-fee programs. In the program's campaign details, add: "BumpCast keeps a perpetual license to each approved video once its flat fee is paid; the commission is extra pay, not a condition of the license." Until Trybe confirms that works, assume a video's ads must come down within 5 business days if commission payments lapse.
   - **Revisions:** one revision per video, requested within 2 days.
   - **Products:** add "BumpCast Pro" by hand (there's no store to import from) with samples off. Pro comes as a code, not a shipped sample.
   - **Brief:** paste the program description, both briefs and the rules below.
2. **Check the connected Meta ad account.** Trybe ads must go through the ad account connected in Trybe, which must stay connected for 12 months after the campaign. Confirm it's BumpCast's ad account `act_2805776443152912` (the one the daily Meta task runs). If it's a different one, reconnect it before the first approved video.
3. **Pro for creators:** use the existing "Sideshift creators 3 months free" offer. Its codes are generic BumpCast Pro Annual codes, 500 of them, valid until Jan 31, 2027, shared with Sideshift. Both campaigns take the next unused code from one list, `.asc/offer-codes/creator-codes.md` (gitignored), so no code goes out twice. Send each code in Trybe chat on the day you accept the creator.
4. **Check flyers' routes before accepting:** add the creator's flight in BumpCast. If it gets a full forecast (not "outlook" or "Notify me"), the route qualifies. Edmonton and Halifax are just outside coverage.
5. **Review the same day:** an approved video is paid and licensed at that moment. Never run or post a video you haven't approved: Trybe's terms call that a material breach and bill it as approved. A rejected video is never paid, and you can't use it.
6. **Building an ad from a Trybe video** (also the daily Meta task's rule, once it runs Trybe videos):
   - The destination URL carries `trybe=<trybe_id>`, the last 8 characters of the submission id. Take the page's Superwall link from `docs/release/meta/config.json` (`install.link/pk_YaoU5p3VsalDAlF6PmSFx/meta-mvrg5n78?...` for Turbulence, `meta-mvrg6xu2` for Tracker, `meta-mvrg5k1s` for standard) and add `&trybe=<trybe_id>` to the end.
   - The ad name ends with the Trybe ID, for example `ugc-flight-maya-<trybe_id>`.
   - Publish from the connected ad account. Partnership ads go out with the creator's handle and Meta's "Paid partnership" label; a plain BumpCast ad works too.
   - Don't remove or change the tracking Trybe adds on export.
7. **News:** when a turbulence story breaks, message creators in Trybe chat with the story link and the facts. A news video is one of the Talk about it videos and pays the same.

**Who gets which brief**

| Creators | Videos |
|---|---|
| 3 flyers (flight booked inside coverage) | Up to 2 On the flight, plus 1 Talk about it |
| 3 talkers | Up to 2 Talk about it, more only if you ask |

**Dates:** accept the soonest flyers first. First videos by Nov 8 give you a read on hooks before Thanksgiving week. Holiday videos are due by **Nov 13**, so they're approved and in Meta's review before ads run Nov 16–26.

---

## Program description (paste)

**BumpCast: nervous flyers**

BumpCast is an iPhone app that forecasts turbulence for your exact flight. You add your flight number, and it tells you in plain words when the bumps will come, how strong they'll be and when they'll end. It's built for nervous flyers and covers flights in the continental US and southern Canada.

We're looking for creators who've felt nervous about flying, now or in the past, to make short videos we'll run as ads on Instagram and Facebook. Flying soon? Even better: we want to see the forecast next to what your flight really felt like.

**What you get**
- CA$10 for each approved video (up to 3 if you're flying, 2 if not).
- 10% of everything we spend running your video as an ad. The better your video does, the more we spend on it, and the more you earn.
- 3 months of BumpCast Pro, free. It doesn't renew, so you're never charged.
- We may run your video as a partnership ad from your Instagram handle.

**Who we're looking for**
- 18 or older, in the US or Canada, with an iPhone.
- You've felt nervous about flying. It doesn't need to be extreme, but it does need to be true.
- Comfortable talking to camera.
- Ideally, a flight booked before Dec 31 within the continental US or southern Canada (not Hawaii, Alaska, Mexico or international). If you're flying in the next two weeks, we'll accept you first.

**When you join, tell us:** where you live (state or province), and your soonest flight with date, airline, flight number and route (for example, "Nov 6, Delta DL 1234, Atlanta to Denver"). No flight booked? Just say so.

---

## Welcome message to accepted creators (paste in Trybe chat)

Welcome aboard! Here's how to start:

1. **Get BumpCast Pro.** Install BumpCast, then open this link on your iPhone: [redeem link]. (Or in the App Store, tap your profile picture → Redeem Gift Card or Code and type [code].) It's 3 months free and never renews.
2. **Add your flight** by its number, even if it's weeks away. The forecast appears 48 hours before departure.
3. **Read the two briefs** in the program. Flyers: On the flight is your main video. Everyone: Talk about it.
4. **Upload to Trybe,** not to your own accounts. We review within a day. Approved videos are paid through Trybe.
5. **Questions?** Ask here in Trybe chat.

Holiday videos are due by Nov 13. Your first video is welcome any time before then.

---

## Rules for every video (paste at the end of each brief)

**Delivery**
- Vertical 9:16, 1080p or higher, 15 to 45 seconds.
- Upload the original file from your camera roll. No TikTok or Instagram watermark, no stickers, no burned-in captions or music. We add text and captions in the ad, so leave room at the top and bottom.
- Record the hook three ways (three different first lines) and upload them together, so we can test which one works best.
- Clear sound: face the camera, somewhere quiet, unless you're on the plane.

**Always**
- Say the name clearly: **BumpCast**.
- Use real forecasts from the app, from your own flight or another real upcoming flight. Screen-record them yourself.
- Keep it calm. BumpCast's whole point is that turbulence is normal and can be forecast. Funny and honest are great. Scary isn't.
- If you also post the video on your own accounts after it's approved, mark it as a paid partnership and add #ad.

**Never**
- Say BumpCast keeps you safe, predicts every bump or is always right. It's for comfort and planning.
- Say it treats or cures anxiety or fear of flying. Your own experience ("it helps me feel calmer") is fine if it's true.
- Use scary edits: screams, alarm sounds, crash or emergency footage.
- Use footage of real incidents or injured people.
- Fake or exaggerate turbulence, or film on the ground as if you were in the air.
- Film flight attendants or other passengers' faces.
- Unbuckle, stand up or ignore the crew to get a shot.
- Mention or criticize other apps or airlines.
- Post the video anywhere before we approve it.

**Things you can say about BumpCast**
- "It forecasts turbulence along your exact route, minute by minute."
- "It tells you when the bumps start, how strong they'll be and when they end."
- "The forecast comes 48 hours before departure, and it updates 24, 6 and 2 hours out."
- "It works in airplane mode, because the forecast is saved on your phone before you board."
- "There's a Lock Screen countdown to the next bumpy stretch."
- "It has guided breathing timed to the next bumpy stretch."
- "It's free to try, for flights in the continental US and southern Canada."

---

## Brief 1: Talk about it (everyone) (paste)

**The idea:** a 20 to 40 second talking-head video about flying as a nervous flyer, with BumpCast as the thing that helps. Unlike an organic post, this one is an ad, so BumpCast is the point, not a side mention. It still has to sound like you.

**Shape**
1. Hook (first 2 seconds): one of the hooks below, or your own. Record three.
2. The feeling: one honest line about what flying is like for you.
3. BumpCast: show your phone, or cut to your screen recording of a real forecast (grade, then the timeline). Say what it showed: "A few bumps around 40 minutes in, then smooth to landing."
4. Why it helps: knowing when the bumps come, and when they end.
5. Close: "It's called BumpCast. Check your flight before you fly."

**Angles (pick one per video)**
- **The night before:** your pre-flight routine, with BumpCast as the step that settles you.
- **Tips:** two or three honest nervous-flyer tips, with BumpCast as the main one.
- **Flying home for the holidays (due by Nov 13):** checking your Thanksgiving or holiday flight. Canadian creators: say "flying home for the holidays".
- **Turbulence in the news (only when we message you):** see below.

**Hooks**
- "If you hate turbulence, do this the night before you fly."
- "I used to spend the whole flight waiting for the bumps. Now I know when they're coming."
- "Nervous flyer here. This is the app I check before every flight."
- "Flying home for Thanksgiving and dreading the turbulence?"
- "Me checking whether my holiday flight will be bumpy."

**Getting the screen recording:** add any real flight leaving in the next 48 hours (yours, or one on a route you fly) and record its forecast.

**When turbulence is in the news**
We'll message you the story link and the facts. Upload within 24 hours if you can.
1. Hook: "You've probably seen the turbulence story. As a nervous flyer, here's what helps me."
2. One or two calm facts from our message or the list below. Don't guess at causes or add details that weren't reported.
3. "Turbulence is weather, and weather can be forecast. I check my flights on BumpCast before I fly."
4. "And keep your seatbelt on whenever you're seated."

Calm facts you can use:
- The most common bumps at cruise come from fast winds next to slower air, and planes are built for far more than that.
- Bumps over mountains follow the terrain and usually pass once you're beyond them. Crews plan their altitudes around them.
- Crews ask you to keep your seatbelt fastened whenever you're seated, and that's the best protection there is.

Never say BumpCast would have predicted that flight, show the news footage itself, joke about the incident, or blame the airline.

---

## Brief 2: On the flight (flyers) (paste)

**The idea:** BumpCast told you when the bumps would come. Show the forecast, then show the moment it happened.

**When:** upload within 3 days of landing. One video per flight, up to 2 flights.

**Before you fly**
- Add your flight in BumpCast. The forecast appears 48 hours before departure.
- The night before, screen-record the forecast: the grade (for example, "A few bumps"), then scroll the timeline to the bumpy stretch. Record it again at the gate.
- Check that Live Activities are on for BumpCast (Settings → BumpCast → Live Activities), so the countdown shows on your Lock Screen.

**On the flight (seatbelt on the whole time)**
- After takeoff, if the countdown hasn't started, tap "We've taken off" in the app.
- Film your Lock Screen when it shows the next stretch, like "Next: light chop in about 6 min".
- When the stretch arrives, film something calm that shows it: a drink on the tray table, the wing out the window, the seatbelt sign coming on.
- Film again once it's smooth.
- After landing, rate the flight in the app.

**Shot list (20 to 45 seconds)**
1. 0 to 2 seconds: the hook, to camera or over the window. Record three.
2. The forecast screen recording: grade, then timeline.
3. The Lock Screen countdown in the air.
4. The bumps (drink, wing or seatbelt sign).
5. Smooth again, plus your reaction.
6. Optional: the rating screen after landing.

Upload the clips as one edited video **and** the separate raw clips, so we can cut more versions.

**Hooks**
- "This app told me exactly when the turbulence would start."
- "It said light chop in 6 minutes. Watch."
- "Nervous flyer test: does a turbulence forecast actually work?"
- "I knew the bumps were coming minutes before they did."
- "My flight home: forecast vs. reality."

**If the forecast was off:** don't upload the comparison, and don't fake it. Rate the flight in the app, make a Talk about it video instead, and tell us how it went.

---

## Reviewing videos (for you)

- Approve, request a revision or reject in Trybe. Your comment goes to the creator as BumpCast's words, so keep it short and specific ("Great. Please re-record the hook without the TikTok watermark").
- Reject anything that breaks the Never list. Request a revision for fixable delivery problems (watermark, horizontal, quiet audio).
- Approving charges CA$10 plus Trybe's fee straight away. Commission on ad spend follows monthly, for as long as the video runs.
- Once ads are running, rank videos by spend, ROAS and thumbstop in Trybe to see which hooks and creators to ask for more of.
