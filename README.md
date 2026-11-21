# ARToronto

Public AR art on the street in Toronto. This repo holds the prototype phone app for the Yonge Spine piece (a beating sphere that several people see in the same place, walk inside, and drive with their combined movement), heading toward Nuit Blanche 2027.

The design notes live in the artwork's own repo (`art-studio/installations/ar/`). This repo is code only.

## What's here

| Path | What |
|---|---|
| `ios/` | Native iPhone app (Swift + RealityKit). Right now: **Hello AR**, one green sphere 1.5 m ahead that beats at 72 bpm. You can walk inside it. Tap to re-place it. |
| `ios/project.yml` | XcodeGen spec. The Xcode project is generated in CI, never committed. |
| `world.json` | Shared world description (sphere locations, colour, pulse) for every client. Locations are placeholders. |
| `.github/workflows/ios-build.yml` | Builds an **unsigned** `.ipa` on a GitHub-hosted Mac (free for public repos). |

Planned: `web/` (GPS probe for iPhone Safari), `server/` (shared room so phones see the same beat).

## Getting the app onto an iPhone (free Apple ID, no Mac)

The cloud build makes an unsigned app. You sign and install it from Windows with [Sideloadly](https://sideloadly.io) and a free Apple ID. Apple's free-account limits: the install stops opening after **7 days** (re-run Sideloadly), and **3** such apps per phone at a time.

**One-time setup**

1. Install **iTunes** and **iCloud** from apple.com (not the Microsoft Store). Sideloadly needs them to talk to the phone.
2. Install Sideloadly.
3. Use a **spare Apple ID**, not your main one. Sideloadly is closed-source and asks for the real password.

**Each build**

1. Open the repo's **Actions** tab, then the latest green **iOS build** run. Download the artifact under *Artifacts*. It's a `.zip` holding the `.ipa`, so unzip it.
2. Plug the iPhone into the PC by USB, unlock it, and tap *Trust* if asked.
3. In Sideloadly, pick the iPhone, drag in the `.ipa`, enter the spare Apple ID, and press **Start**.
4. On the first install only:
   - Settings → Privacy & Security → **Developer Mode** → on. The phone restarts.
   - Settings → General → **VPN & Device Management** → trust the Apple ID.
5. Open **ARToronto**. The box at the bottom shows the build number, so you can tell which build is installed.

A new build starts on every push that touches `ios/`. Start one by hand from Actions → *iOS build* → **Run workflow**.

## When to pay Apple $99

Pay once other people need the app without plugging into your PC (TestFlight install links), or once 7-day installs get in the way. The cloud build stays the same. Only the signing step changes.
