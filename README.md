<p align="center">
  <img src="docs/icon.png" width="128" alt="Launchwatch icon">
</p>

<h1 align="center">Launchwatch</h1>

<p align="center">
  Keeps an eye on the sites you have already launched, from the menu bar.<br>
  Says nothing while they are fine. Tells you when one breaks.
</p>

<p align="center">
  <a href="https://github.com/BRIJRAJ-02/launchwatch/actions/workflows/ci.yml"><img src="https://github.com/BRIJRAJ-02/launchwatch/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black" alt="macOS 14+">
  <img src="https://img.shields.io/badge/SwiftUI-native-black" alt="SwiftUI">
  <img src="https://img.shields.io/badge/license-MIT-black" alt="MIT">
</p>

<p align="center">
  <img src="docs/down.png" width="460" alt="The Launchwatch panel. The headline reads acme-rockets.com is down. Its row is open, showing a timeline of recent events, a strip of 28 small squares for the last seven days with two of them red, uptime over seven days, the usual response time, the certificate date and buttons to check now, open the site, open the report and remove. Five other sites sit below with green dots, response-time sparklines and scores.">
</p>

## What it does

[Launchcheck](https://github.com/BRIJRAJ-02/launchcheck) audits a site once, before it goes live. Launchwatch is what happens after: it keeps checking the sites that are already live, and speaks up when one of them stops being fine.

- **Is it up?** One request to the home page every five minutes. Two failures in a row before anything is called down, so a dropped request alarms nobody. A failed check is tried again 30 seconds later.
- **Is it slow?** Slow means slow for that site: three times its own median over the last day, twice in a row. There is no fixed number.
- **Is the certificate about to run out?** A warning at 14 days, another at 3, and one when it has expired.
- **Has it drifted?** Every six hours the Launchcheck engine reads up to 25 pages and compares them with last time. You hear about a noindex that appeared, a robots.txt that started blocking everything, a sitemap that disappeared, a home page title or canonical that changed, a new problem that would have stopped the launch, and a score that fell by five or more, with what caused it.
- **Once, not forever.** Each of these is said one time, when it starts. It is not repeated while nothing has changed.
- **Not fooled by your own Wi-Fi.** When the Mac itself is offline, checks pause and no site is marked down.
- **The week in one sentence.** On Monday at 9:00, or the first time the Mac is awake after that, one notification sums up the last seven days: "Last week: 6 sites, 99.9% up, 1 outage (acme-rockets.com, 12 minutes), harbour-coffee.co's certificate expires in 9 days, 1 score fell." When nothing happened it says so: "Last week: all 6 sites stayed up." It is sent once a week and never twice, and stays in the panel until the next one.
- **The whole report, one click away.** With [Launchcheck](https://github.com/BRIJRAJ-02/launchcheck) installed, an expanded row gains Open report, which opens that site there. Without it the button is not shown.

<p align="center">
  <img src="docs/fine-dark.png" width="460" alt="The panel in dark mode with the headline All 6 sites are fine">
</p>

## Install

### Download

Get `Launchwatch-x.y.z.dmg` from the [latest release](https://github.com/BRIJRAJ-02/launchwatch/releases/latest), open it and drag Launchwatch to Applications. It runs on Apple Silicon and Intel, macOS 14 or later.

The app is not notarized, so macOS blocks the first launch. Either allow it under System Settings → Privacy & Security → Open Anyway, or run:

```bash
xattr -dr com.apple.quarantine /Applications/Launchwatch.app
```

### Build from source

Requires Xcode 16 or later (for the Swift toolchain). The audit engine is fetched from the [Launchcheck](https://github.com/BRIJRAJ-02/launchcheck) repository as a package.

```bash
git clone https://github.com/BRIJRAJ-02/launchwatch.git
cd launchwatch
./scripts/build-app.sh --install   # builds, copies Launchwatch.app to /Applications, launches it
```

## Using it

| Do this | To |
|---|---|
| Click the menu bar icon | Open the panel |
| Type an address, press Return | Watch a site. It is checked once first, and not added if it does not answer |
| Click a row, or press Return on it | See recent events, the last seven days as a strip, uptime, usual response time and the certificate date |
| Rest the pointer on a square in the strip | See which six hours it stands for and how they went |
| Click Open report in an open row | Open the full report for that site in Launchcheck, when Launchcheck is installed |
| Click the Last week line, when it is cut short | Read the whole summary |
| ↑ and ↓ | Move through the sites |
| ⌘R | Check every site now |
| ⌘N | Jump to the address field |
| ⌘, | Show or hide the settings |
| Esc | Close the panel |
| ⌘Q | Quit |
| Right-click a row | Check Now, Open Site, Open Report in Launchcheck, Copy Address, Remove |
| Right-click the menu bar icon | Check Now, Quit |

The menu bar icon is plain while everything is fine. It gains an amber or red dot when a site needs a look, and a number only when more than one does.

Settings are in the panel, behind the gear: how often to check uptime (1, 5 or 15 minutes), how often to run the audit (1, 6 or 24 hours), notifications, the weekly summary, and opening at login. With the weekly summary off, nothing is written and the line leaves the panel. With notifications off and the summary on, it is written to the panel without a notification.

<p align="center">
  <img src="docs/settings.png" width="460" alt="The panel with its settings open: check uptime every 1, 5 or 15 minutes, run the audit every 1, 6 or 24 hours, notifications, weekly summary on Mondays and open at login">
</p>

<p align="center">
  <img src="docs/summary.png" width="460" alt="The panel with last week's summary open under the list: Last week: 6 sites, 99.9% up, 1 outage (acme-rockets.com, 6 minutes), harbour-coffee.co's certificate expires in 9 days, 1 score fell.">
</p>

## Design notes

- **A verdict, then the evidence.** The largest text in the panel is one sentence that answers "is everything all right?". The list underneath is for when it is not.
- **Color means severity and nothing else.** Red, amber and green, in dots eight points wide. Everything else is the system's text colors and hairlines, so light, dark and Increase Contrast all work.
- **A site that is down is the headline.** Trouble sorts to the top, and one outage outranks any number of smaller worries.
- **Quiet by default.** A row shows a second line only when there is something to say. A score that has not been measured yet is an empty ring, not a zero.
- **Sparklines that mean something.** The top of each chart is twice that site's usual time, so a steady site draws a calm line through the middle and only a real spike reaches the top. Outages sit on the floor in red. Where nothing was measured, the line breaks.
- **A week you can see.** The open row shows the last seven days as 28 squares, four a day, the same squares as the page map in Launchcheck. Grey where the site was up, red where it was down, paler where nothing was checked because the Mac was asleep or the site was not watched yet. Down means what it means everywhere else here: two failures in a row, not one dropped request.
- **Last week stays out of the way.** The summary is one grey line under the list, not under the headline, because the headline is about now. A quiet week fits on the line. A longer one is cut short and opens when clicked.
- **Numbers that hold still.** Every figure uses tabular digits. Addresses are in SF Mono; nothing else is.
- **Motion with a reason.** Rows open in 200 ms and close faster. Buttons dip when pressed. Nothing animates from the keyboard, nothing loops except one small arc while a check is running, and all of it stops for Reduce Motion.
- **Plain words.** "acme-rockets.com is down: the server refused the connection." No codes unless the server sent one.

## How it is built

```
Sources/
  LaunchwatchCore/   UI-free watcher: pulses, audits, event detection, scheduling, the files it keeps
  Launchwatch/       the menu bar item, the panel, notifications, snapshot rendering
Tests/               event detection, de-duplication, scheduling, the weekly summary and when it is due, the uptime strip, persistence, the watcher end to end with stubs
scripts/             build-app.sh bundles the app and the DMG; make-icon.swift draws the icon in code
```

Where each reading comes from:

| Reading | Source |
|---|---|
| Up or down, response time | One `URLSession` request to the home page on a fresh connection, timed to the first byte of the answer |
| Certificate expiry | The leaf certificate from the server trust, read in the session's authentication challenge |
| Score and drift | `Auditor` and `Drift.compare` from LaunchcheckCore, on 25 pages, without external links or image weighing |
| Offline | `NWPathMonitor`, plus the error a request gives when there is no connection |
| Uptime strip and weekly summary | The week of stored pulse samples and the event log, nothing fetched |
| Open report | `launchcheck://open?site=example.com`, offered only when `NSWorkspace` finds an app for that scheme |

Event detection, scheduling, the weekly summary and the uptime strip are pure functions: state and a reading go in, a new state and any events come out, and the clock and the calendar are arguments. The tests never touch the network.

Sites, events and settings live in `~/Library/Application Support/Launchwatch`, along with a week of pulse samples and the latest audit report for each site. Nothing leaves your Mac except the requests to the sites you added.

### Developing

```bash
swift build && swift test       # or open Package.swift in Xcode
./scripts/build-app.sh --open   # build and launch the app bundle
./scripts/build-app.sh --dmg    # universal build, packaged as build/Launchwatch-<version>.dmg
.build/debug/Launchwatch --snapshot docs        # re-render the README screenshots with sample data
.build/debug/Launchwatch --pulse example.com    # one real pulse, printed
.build/debug/Launchwatch --summary              # what the weekly summary would say right now
LAUNCHWATCH_HOME=/tmp/lw .build/debug/Launchwatch   # run against a scratch data folder
```

## License

[MIT](LICENSE)
