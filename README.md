# Vory

A native iPhone / iPad remote for a self-hosted [Hermes Agent](https://hermes-agent.nousresearch.com) backend.
The agent runs on **your** machine; the app is a full Desktop-class client over the dashboard's REST API and
the `/api/ws` JSON-RPC socket. Nothing is hardcoded: on first launch you enter the URL of your own
`hermes serve` / `hermes dashboard` and how you authenticate to it.

- iOS 27 SDK, SwiftUI, Swift 6 strict concurrency, iPhone + iPad, light and dark.
- Stock Liquid Glass only (`glassEffect`, `GlassEffectContainer`, glass button styles, system bars).
- Streams tokens as Hermes writes them, tool cards, approvals/clarify/secret cards, model picker, live token chip.
- Attachments (Photos, camera, Files, voice memos, paste) round-trip through your gateway.
- A Home tab: your month in numbers, your bots, the chats to pick back up and what changed while you were away,
  as cards you can order, size, hide and drag; the same numbers in a widget and on the watch face.
- Hermes Projects, a Files browser, a Bots tab, slash commands with completions, todo checklists, and
  bot-to-bot messages shown as "Messaged X" notices you can tap to read the other bot's chat.
- Settings mirrors the web dashboard: model, config, env/API keys, tools, skills, MCP, approvals, cron, sessions,
  plugins, channels, system — all scoped to the selected profile with `?profile=`.
- Any number of saved gateways (home, office, travel). One gateway covers every profile on that machine.
- Cloudflare Access service-token headers are optional and off unless both values are set.
- Face ID lock, Keychain storage, redacted logs, reconnect with backoff.

## Requirements

- Xcode with the **iOS 27 SDK** (deployment target iOS 26.0: runs on iOS 26 and 27).
- A Hermes Agent install with the dashboard running (`hermes serve` or `hermes dashboard`), reachable from the phone.
- For push notifications from the background: an Apple Developer team (APNs key) and the `server/hermes-push` companion.

Open `Vory.xcodeproj`, set your team and bundle identifier on the `Vory` and `HermesLiveActivity`
targets, and run. The app ships as `com.vorantx.vory`, with the Live Activity extension as
`com.vorantx.vory.LiveActivity`.

### Installing on a physical device

Running in the simulator needs nothing. Installing on an iPhone or iPad needs a signing identity,
and there are three things that commonly block it:

1. **An expired or missing development certificate.** `security find-identity -v -p codesigning`
   must list at least one `Apple Development:` identity. If it prints `0 valid identities found`,
   Xcode has to issue a new one: Xcode → Settings → Accounts → select your Apple ID → Manage
   Certificates → **+** → Apple Development. Delete the expired one from Keychain Access first so
   Xcode does not keep picking it.
2. **Push Notifications on a free account.** A free "Personal Team" cannot provision
   `aps-environment`, and a target that declares it fails with *No profiles for '<bundle id>' were
   found*. This project therefore ships **without** that entitlement, so a personal team can build
   and install. The app notices at runtime and says so in Settings → Notifications; Live Activities
   and in-app notifications still work. With a paid membership, add it back the normal way: target
   → Signing & Capabilities → **+ Capability** → Push Notifications.
3. **A bundle identifier someone else already registered.** App IDs are globally unique. If
   registration is refused, change `PRODUCT_BUNDLE_IDENTIFIER` on both the app and the
   `HermesLiveActivity` target to a reverse-DNS name you control (the extension must stay a child
   of the app's id, e.g. `com.example.hermesremote` and `com.example.hermesremote.LiveActivity`).

Free personal-team provisioning profiles expire after 7 days, so the app stops launching after a
week until you rebuild from Xcode. `DEVELOPMENT_TEAM` in `project.pbxproj` holds whichever team
Xcode last wrote there; clear it before sharing the repository.

If Xcode reports *"The certificate for this server is invalid"* for `developerservices2.apple.com`,
that is the network in front of you, not the project: a VPN or proxy doing TLS inspection. Verify
from a terminal with
`openssl s_client -connect developerservices2.apple.com:443 2>/dev/null | openssl x509 -noout -issuer`
— a genuine issuer is `Apple Public EV Server RSA CA 1 - G1`. Anything else means something is
intercepting, and Xcode is right to refuse. Disconnect that tunnel and retry.

## Connecting

Settings → Gateways → Add Gateway (also the first-launch screen). Enter:

1. **Name** — anything, e.g. `Home`.
2. **Gateway URL** — the dashboard base URL exactly as you reach it, e.g. `https://hermes.example.com`,
   `https://gateway.example.com/hermes` (reverse-proxy prefix), or `http://192.168.1.20:9119` on the LAN.
   The app strips trailing slashes and pasted `/api/...` suffixes. Do **not** enter a chat-webui, an OpenAI
   `/v1` endpoint, or an SSH host.
3. **Authentication**
   - **Session token** — for a gateway with no auth gate (bound to loopback, or reached through a tunnel to the
     loopback bind). Paste `HERMES_DASHBOARD_SESSION_TOKEN`. The app sends it as `X-Hermes-Session-Token` and as
     `?token=` on the WebSocket.
   - **Username & password** — for a gateway whose auth gate uses the basic-auth provider
     (`HERMES_DASHBOARD_BASIC_AUTH_*`). The app runs the RFC 8252 native flow against
     `/auth/native/authorize` + `/auth/password-login` + `/auth/native/token`, keeps only the resulting access +
     refresh tokens, and never stores the password.
   - **Sign in with browser** — Nous Portal / OIDC via the system browser (PKCE, loopback redirect,
     `/auth/native/token`). Tokens refresh through `/auth/native/refresh`; when the refresh token dies the app asks
     you to sign in again and Settings stays reachable.
4. **Cloudflare Access (Advanced, optional)** — if your dashboard sits behind Cloudflare Access, create a service
   token and enter `CF-Access-Client-Id` and `CF-Access-Client-Secret`. Both headers are then sent on every HTTP
   request **and** on the WebSocket upgrade. Leave both empty when you have no Access policy; an empty pair does
   not bypass anything. Safari's Access cookie is not shared with the app.
5. **Test Connection** — must pass all three legs before Save is enabled:
   - `GET /api/status` returns JSON. If it returns HTML you are looking at a login page (Access, a proxy, or a
     non-dashboard URL): use the `hermes serve` URL, add the Access service-token headers, and confirm the tunnel
     upgrades WebSockets.
   - the credential is accepted (`/api/auth/me` for gated gateways, a token-gated endpoint otherwise).
   - `wss://…/api/ws` opens and `gateway.ready` arrives. HTTP-pass / WebSocket-fail means the proxy does not
     forward Upgrade requests, Access blocks the socket, or `dashboard.public_url` does not match the host you
     typed (DNS-rebinding guard).

Telling `/api/status` JSON from an Access page quickly:

```bash
curl -sS -H "CF-Access-Client-Id: <id>" -H "CF-Access-Client-Secret: <secret>" https://hermes.example.com/api/status | head -c 200
```

JSON starting with `{"version":` is the dashboard; anything starting with `<!DOCTYPE html>` is a login page.

Cloudflare Tunnel, Tailscale, plain LAN and public HTTPS are all fine — the app only cares about the URL you type.
Plain `http://` is permitted (needed for LAN installs); the form warns when the host is not on a private network.

## Chat

- **Chats** lists stored sessions (`GET /api/sessions?order=recent`), with search, swipe to pin/archive/delete and a
  *Needs you* badge when a card is waiting.
- Opening a chat calls `session.resume`; the compose button calls `session.create`. Messages go through
  `prompt.submit`; `message.delta` streams into the bubble; `tool.start` / `tool.complete` become glass cards;
  `message.complete` finalizes and drains the local queue.
- **Model picker** (toolbar menu) lists `GET /api/model/options` grouped by provider. A mid-chat pick sends
  `config.set model "<model> --provider <slug> --session"` — session only, never `model.default`. Reasoning effort,
  fast mode and per-session YOLO live in the same menu.
- **Chat header**: the navigation bar is hidden in a chat; a floating glass header (back circle, a pill with the
  bot's avatar above the title and its live status, an … circle) sits over the thread, which scrolls under it and
  under the composer. Tap the pill for the bot's info sheet (`/api/profiles` entry + `GET /api/profiles/{name}/soul`);
  model picker, context breakdown and bot info live in the … menu.
- **Tab bar**: four tabs, Home, Chats, Bots and Settings by default, every one of them movable and all but Chats
  and Settings removable (Appearance › Tab bar offers Files, Projects and Status too), plus a detached glass New
  Chat button, like Messages. The bar hides under the keyboard. Settings › Home picks the tab the app opens on.
  Connection status lives in the profile switcher menu.
- **Per-turn stats**: each finished reply shows `tokens · tok/s · seconds`, exact when `session.usage` gave an
  output count before and after the turn, estimated (`~`) from streamed characters otherwise. Appearance › Chat
  toggles tool calls, reasoning, stats and system notes.
- **Composer** matches the Messages bar: round attach button outside, one thin field with the mic / send / stop
  control inside its trailing edge. Long-press a chat row for a preview with Open / Pin / Archive / Delete.
- **Transcript** reads like Messages: grey bot bubbles, your bubbles in the accent you chose, time separators
  after a 15-minute pause, drag left to peek at per-message times, long-press a bubble for Reply / Copy /
  Edit & resend / Share, and the tab bar hides inside a chat. Reply quotes the bubble above your next message.
  Tool cards show the command and output as capped code blocks; a `todo` tool call draws as a checklist.
  Appearance › Chat has the display options: fold tool cards after the turn, hide tool output, compact cards,
  current step only, wide replies and a text size.
- **Bot-to-bot messages**: when a bot messages another (a quiet `hermes -p <bot> chat … -q "Message from …"`
  run through the terminal tool, or the `message_agent` tool), the chat shows a centred "Messaging X…", then
  "Messaged X", then "Message from X" with the answer folded under it, instead of a shell transcript. Inbound
  "Message from 🤖 X:" rows show the same way. Tap a notice to open X's own Bot Chat read-only.
- **Bot colours** (Appearance › Bot colours, or the bot's card): one accent per profile, used for the avatar in
  the title pill, the Bots list and that bot's Live Activity. Stored on the device only.
- **Profile card** (tap the title pill › Profile): colour, description (`PUT /api/profiles/{name}/description`)
  and default model (`PUT …/model`); **SOUL.md** opens in an editor that saves with `PUT …/soul`.
- **Notifications** lead with the bot's name and carry the chat title as subtitle; finished-turn notifications
  have an inline **Reply** action, approvals have **Approve once / Deny**.
- **Bots** are the gateway's profiles: each row is a profile with its SOUL.md, model and its own sessions
  (`/api/sessions?profile=`). Opening one of its chats switches the selected profile first. Hosted group rooms
  (`groups.*`) are a section underneath when the gateway offers them, with `groups.create {name}`.
- **Approvals** arrive as gateway→client JSON-RPC requests. The card offers Once / Session / Always / Deny and
  answers with `{"choice": …}` on the same request id (or `approval.respond` for queued approvals). Clarify, sudo,
  secret and vault prompts are handled the same way; secrets use `SecureField` and are never logged.
- Slash commands use `commands.catalog` for suggestions (on the word being typed) and `slash.exec` to run, with
  `command.dispatch` as the fallback on older gateways; `/approve`, `/deny`, `/stop`, `/new`, `/title`, `/model`
  and `/reasoning` are handled locally, and commands the catalog marks desktop-only say so.
- Attachments: images → `image.attach_bytes`, PDFs → `pdf.attach`, everything else → `file.attach` (data URL) and
  the returned `@file:` reference is appended to your message. Hold the mic button for on-device dictation.

## Home

The Home tab is a dashboard of cards: a greeting by name (Settings › Home), the **Overview** (sessions, messages,
tokens, active days, peak hour and top model for 7, 30 or 90 days, with thirteen weeks of activity blocks and the
gateway's cost estimate, from `GET /api/analytics/usage?days=`), **Bots** with their status, **Pick up where you
left off** and **Since you were here**, which sums up on the phone what changed while you were away. Cards can be
reordered, resized and hidden from Settings › Home, by pressing and holding a card, or by dragging one card onto
another on Home itself. The chats cards show the current bot's chats or every bot's. An **Overview** widget and
watch complications carry the same numbers and refresh themselves every half hour.

## Projects, Files and Bots

- **Projects** are the gateway's (`projects.list`, `projects.create`, `projects.tree`): Chats filters by project,
  every chat shows its project chip, new chats can start inside one, and Settings › Projects manages them. A
  gateway without projects answers `-32601` and the app hides the feature.
- **Files** browses the gateway's folders (`GET /api/files`, downloads, uploads), hides dot files behind an eye
  button, loads big folders in pages and recovers when a listing stalls.
- **Bots** lists the gateway's profiles with their faces, status, SOUL.md and model; each bot has a colour, a
  face and a finish of its own, and Settings › Bots sets how much they move (lively, calm or still) and whether
  they tilt with the phone.
- **Plugins** (Settings › Plugins) lists what the gateway loads, Vory's own companion first, from
  `GET /api/dashboard/plugins/hub`.

## Settings API map

| Screen | Endpoints |
|---|---|
| Gateways | app-local (Keychain) + Test: `/api/status`, `/api/auth/me`, `/api/auth/ws-ticket`, `/api/ws` |
| Profile | `GET /api/profiles`, `GET /api/profiles/active`, `POST /api/profiles`, `DELETE /api/profiles/{name}` |
| Projects | `projects.list`, `projects.create`, `projects.update`, `projects.delete`, `projects.tree` (JSON-RPC) |
| Plugins | `GET /api/dashboard/plugins/hub` (read-only) |
| Home | `GET /api/analytics/usage?days=`, `GET /api/sessions?order=recent&limit=100` |
| Model | `GET /api/model/options`, `GET /api/model/auxiliary`, `POST /api/model/set` |
| Config | `GET /api/config`, `GET /api/config/schema`, `PUT /api/config {config:{…}}` (deep-merge) |
| API keys & env | `GET /api/env`, `PUT /api/env {key,value}`, `DELETE /api/env {key}` |
| Tools | `GET /api/tools/toolsets`, `PUT /api/tools/toolsets/{name} {enabled}` |
| Skills | `GET /api/skills`, `PUT /api/skills/toggle {name,enabled}` |
| MCP | `GET /api/mcp/servers`, `PUT /api/mcp/servers/{name}/enabled`, `POST …/test`, `DELETE …/{name}` |
| Approvals | `approvals.mode` / `approvals.timeout` via `PUT /api/config` |
| Cron | `GET/POST /api/cron/jobs`, `POST …/{id}/pause|resume|trigger`, `DELETE …/{id}` |
| Sessions | `GET /api/sessions`, `GET /api/sessions/search`, `GET /api/sessions/stats`, `DELETE /api/sessions/{id}` |
| Channels | `GET /api/messaging/platforms` (read-only) |
| System | `GET /api/status`, `GET /api/logs` (grouped into entries, 5 shown + *Show more*), `POST /api/ops/doctor` |
| System › Maintenance | `GET /api/hermes/update/check`, `POST /api/hermes/update`, `POST /api/gateway/restart`, tailed via `GET /api/actions/{hermes-update\|gateway-restart}/status` |
| Appearance (app) | app-local: accent, light/dark override, chat display options, which tabs sit in the bottom bar and in what order (`tabLayout` in UserDefaults) |
| Home (app) | app-local: your name, the tab the app opens on, the cards' order, size and visibility (`home.layout`) |
| Files tab | `GET /api/files`, `GET /api/files/download`, `POST /api/files/upload-stream` |

Every request carries `?profile=<selected profile>`; writes re-GET afterwards and 4xx bodies are shown verbatim.

When the dashboard answers `503 Restart required` (it is serving code older than its checkout on disk after a
`hermes update` or `git pull`), the app already knows: it probes `/api/model/options` on connect, on profile
change and after every reconnect, and shows a Liquid Glass banner above the chat list with an *Update Hermes*
button, badges the Settings tab, and shows the same callout on the Model screen. Restart runs `hermes gateway restart`; Update runs
`hermes update`, which relaunches the dashboard. Both execute on the gateway machine and the app reconnects.

## Notifications

Foreground events render inline. Cards and finished turns that arrive while the app is in the background are
raised as local notifications for as long as iOS keeps the socket alive. True background delivery uses APNs:

1. Allow notifications in Settings → Notifications. The app registers with APNs and publishes
   `<profile home>/push/devices/<install-id>.json` on your gateway (through `/api/files/upload`).
2. Run the `server/hermes-push` companion on the gateway machine with your APNs key
   (`HERMES_PUSH_*` variables — see [server/hermes-push/README.md](server/hermes-push/README.md)).
3. Notifications for approvals carry *Approve once* / *Deny* actions; tapping any notification opens that session
   and card. A Live Activity runs while a turn streams and is ended by the companion when the turn completes.

If you build without an Apple Developer team, registration fails gracefully and the app tells you in
Settings → Notifications; everything else works.

## Security notes

- Gateway URLs, tokens and Access secrets live in the iOS Keychain (device-only, after first unlock).
- Logs never include tokens or secret values.
- The app never writes `model.default`, never opens MCP/UniFi/LLM ports, and ships no server addresses.

## Background push without Apple developer work for users

Users never create an APNs key. The developer runs the tiny relay in `server/push-relay/` (a
Cloudflare Worker holding the APNs key; deploy once, set `VORY_PUSH_RELAY_URL` in
`Tools/release/.env` so the release script bakes it into `VoryPushRelayURL`). Then:

1. The phone mints an install id, a relay secret and an AES-256 key, registers its device token
   with the relay, and writes id + secret + key into its device file on the user's gateway.
2. `hermes-push` on the gateway encrypts each notification (AES-GCM) and posts it to the relay.
   The relay looks up the token and forwards to APNs; it sees ciphertext and tokens only.
3. `VoryNotificationService/` (a Notification Service Extension) decrypts on the phone and
   rewrites the placeholder title/body/category, so actions and deep links work as before.

Live Activity updates and watch complication pushes travel through the relay too, with generic
content only (no extension can decrypt those). Builds without a relay URL fall back to the
bring-your-own-key flow in Settings › Notifications.

**Installing the companion from the app:** Settings › Notifications › *Set up the push
companion…* uploads the relay to `<home>/plugins/vory-push/` and enables it through
`/api/dashboard/agent-plugins/…/enable`; Hermes runs it in-process as a plugin after the next
gateway restart (one tap in the same screen). The systemd/launchd installer remains as a fallback.

## Apple Watch, widgets and complications

- **Watch app** (`VoryWatch/`, bundle `com.vorantx.vory.watchkitapp`): recent chats with the ones waiting for
  you on top, a chat view that streams through the same `VoryCore` runtime as the phone, approval / question /
  secret cards sized for the wrist, and a dictation composer. Gateways arrive from the iPhone over
  WatchConnectivity (every saved gateway plus its secrets, as the application context — encrypted by the
  system, latest wins); a session token can also be typed on the watch. Notifications mirrored from the phone
  carry the same Approve once / Deny / Reply actions.
- **Complications** (`VoryWatchComplications/`, WidgetKit): *Needs you* (waiting approvals), *Current chat*
  (what the agent is working on) and *Context* (gauge), in circular, rectangular, inline and corner families.
- **iPhone widgets**: the same three plus **Overview** (the month's sessions and tokens with the activity blocks),
  as lock-screen accessories and home-screen small/medium widgets, shipped inside the existing
  `HermesLiveActivity` extension. Both read `Widgets/VoryWidgets.swift`. The Overview widget fetches fresh
  numbers itself every half hour.
- **Data path**: the running app writes a `WidgetSnapshot` (attention count, recent chats, context %) into a
  Keychain access group shared by the app, its widgets and the watch app (`…com.vorantx.vory.shared`), so no
  App Group is needed. Providers refresh the session list themselves when the snapshot is older than ten
  minutes. `hermes-push` sends the watch `complication` pushes (throttled to one per three minutes) so faces
  update while nothing is open; it never sends the watch alert pushes, because the phone's are mirrored.
- Tapping any widget or complication opens the chat (`vory://chat/<id>`).
- **Over the iPhone's Bluetooth link watchOS proxies HTTP but not WebSockets**, so the watch reads
  transcripts with `GET /api/sessions/{id}/messages` and polls, and routes prompts, approvals and
  answers through the iPhone over WatchConnectivity (`sendMessage` wakes the phone app). On Wi-Fi or
  cellular the watch uses the live socket directly.

## Vory for Mac

A native macOS app (`VoryMac` target, same bundle id, macOS 26) built from the same views as the phone.
Shared files carry `#if os(iOS)` / `#if os(macOS)` where the platforms differ; Mac-only pieces live in `VoryMac/`.

- **Window**: a rail of pages on the left (every page can be switched on in Settings › Appearance › Sidebar,
  ⌘1–⌘9 open the first nine), the chat list beside the open chat, and the thread and composer in a reading
  column. One window; closing it leaves the menu bar item, which brings it back.
- **Chat**: Return sends, Shift-Return adds a line, drop files or paste images into the composer,
  *File › Import from iPhone or iPad* stands in for the camera, force click a chat row to peek it.
  The Chat menu has New Chat (⌘N), New Chat With… (⇧⌘N), Next / Previous Chat (⌥⌘↓ / ⌥⌘↑),
  Find Chats (⌘F), Stop (⌘.), Approve Once (⇧⌘Y) and Deny (⇧⌘D).
- **Menu bar** in place of the Live Activity: running turns and waiting approvals with Approve / Deny,
  and a badge on the Dock icon for what needs you.
- **Notifications**: the same relay and Companion as the phone; a Mac notification service extension
  decrypts them. On the iPhone, *Settings › Notifications › Quiet for chats driven from a Mac* keeps the
  phone silent for a chat whose last message was sent from the Mac (Companion 1.0.35).
- **Bot looks** follow the phone: it publishes colours, bodies and photos to `<profile home>/push/looks.json`
  and the Mac reads them. The Mac does not write that file.
- **Files**: drop files on the page to upload, drag one out to the Finder, or *Save As…* from the context menu.
- **Widgets** for the desktop and Notification Center (`VoryMacWidgets`): Status, Needs you, Activity,
  Overview and Context, from the same snapshot as the phone's.
- Not on the Mac: Live Activities and the Dynamic Island, the watch link, tilt-driven eyes and haptics.

Run it with the `VoryMac` scheme. It is sandboxed and shares the Keychain group with its extensions, so it
must be signed (an unsigned build cannot read its own credentials).

## Code layout

- `Packages/VoryCore` — everything that talks to a gateway and holds chat state: networking
  (`GatewayURL`, `RequestSigner`, `HermesAPI`, `GatewaySocket`, `NativeAuth`), wire types, `ChatSession`
  + `StreamAssembler`, `GatewayRuntime`, `MaintenanceModel`, Keychain + `ConnectionStore`. No UIKit,
  AppKit, WatchKit or ActivityKit; it builds for iOS, macOS and watchOS. Platform behaviour is injected
  through three hooks in `Runtime/Hooks.swift`: `TurnActivityReporting` (Live Activity on iOS),
  `CardNotifying` (local notifications) and `PushRegistrationSyncing` (device registration).
- `Vory/` — the app's SwiftUI views, push registrar and app lock, compiled for iOS and (minus a few
  iOS-only files) for macOS; the Live Activity controller is iOS-only.
- `VoryMac/` — the Mac app: the window and its rail, the menu bar item, the app delegate, and the stand-ins
  that let shared views compile (`PlatformShims`, `UIKitCompat`). `VoryMacNotificationService/` and
  `VoryMacWidgets/` are its two extensions; they compile the iOS extension sources.
- `HermesLiveActivity/` + `Shared/` — the iPhone widget extension (Live Activity + home/lock-screen widgets),
  the `HermesTurnAttributes` it shares with the app, and the app icon. Dates in the content state travel as
  Unix seconds so the push companion can set them.
- `VoryWatch/`, `VoryWatchComplications/`, `Widgets/` — the watch app, its complications extension, and the
  WidgetKit code shared by both widget extensions.
- `server/hermes-push/` — the APNs relay you run next to Hermes (see its README): `--list`, `--test`,
  `--dry-run`, `install.sh`. The app bundles a copy (`Vory/Resources/hermes-push/`, kept identical
  by a unit test; `Tools/sync-push-companion.sh` refreshes it) so Settings › Notifications › *Set up the push
  companion…* can upload it, its config and your APNs key to `<profile home>/push/` and ask Hermes to run the
  installer. The only thing you do by hand is create the APNs key at Apple.

Build the package alone for another platform with
`cd Packages/VoryCore && xcodebuild -scheme VoryCore -destination 'generic/platform=macOS' build`
(or `watchOS Simulator`).

## Tests

`VoryTests` (Swift Testing): URL normalization, header injection (Access headers absent when empty),
WebSocket ticket/token URL, approval request/response frames, config GET/PUT against a mocked transport, and
streaming delta assembly / code-fence stabilization. Run with ⌘U or

```bash
xcodebuild test -project Vory.xcodeproj -scheme Vory -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Two optional end-to-end suites run against a real gateway when the simulator's environment carries
`HERMES_E2E_URL` and `HERMES_E2E_TOKEN` (they skip otherwise):

- `GatewayIntegrationTests` drives the app's networking stack: the three-leg connection test, REST decoding,
  `client.capabilities`, `session.create`, `prompt.submit`, `message.complete`, usage/context RPCs, then deletes
  the session it created.
- `VoryUITests` drives the real UI: onboarding → form → Test Connection → Save → new chat → send →
  Settings → Tools / Config / Env, saving screenshots to the runner's tmp directory.

```bash
UDID=<simulator udid>
xcrun simctl boot $UDID
xcrun simctl spawn $UDID launchctl setenv HERMES_E2E_URL http://127.0.0.1:9119
xcrun simctl spawn $UDID launchctl setenv HERMES_E2E_TOKEN "$HERMES_DASHBOARD_SESSION_TOKEN"
xcodebuild test -project Vory.xcodeproj -scheme Vory -destination "id=$UDID" -parallel-testing-enabled NO
```

The streaming assertion is skipped (and reported) when the gateway has no AI provider configured.


The same unit tests run against the Mac app (`VoryMacTests`, hosted in it, so the build must be signed):
`xcodebuild test -scheme VoryMac -destination 'platform=macOS'`. Tests that differ by platform (the
four-tab limit on the phone, the unlimited sidebar on the Mac) are behind `#if os(...)`.

### Shipping to TestFlight

`Tools/release/testflight.sh` archives and uploads a build without any interactive Apple login,
using an App Store Connect API key instead of an Apple ID password and 2FA. The build number is one
more than the highest App Store Connect already holds for the app, because it refuses a
`(version, build)` pair it has already seen; `BUILD_NUMBER=` overrides it.

```bash
export ASC_KEY_ID=ABCD123456
export ASC_ISSUER_ID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
export ASC_KEY_PATH=$HOME/.appstoreconnect/private_keys/AuthKey_ABCD123456.p8
Tools/release/testflight.sh
```

Put those in `Tools/release/.env` instead if you prefer; that path is gitignored. The `.p8` itself
should live outside the repository.

The Mac app ships from the same script to the same app record:

```bash
PLATFORM=macos Tools/release/testflight.sh            # archive, export a .pkg, upload
PLATFORM=macos DRY_RUN=1 Tools/release/testflight.sh  # everything but the upload
```

Once, first: add the macOS platform to the app record; create Mac App Store provisioning profiles for the
app and its two extensions with the names in `Tools/release/ExportOptions-macOS.plist`; and have a
Mac installer certificate in the keychain (the `.pkg` is signed with it). `DRY_RUN=1` works for iOS too.

Three things must happen once, in a browser, before the first run, because Apple offers no other
route for them:

1. Accept any pending agreements in App Store Connect. A new account always has the Program
   License Agreement waiting, and uploads are rejected until the Account Holder accepts it.
2. Create the API key with **App Manager** access. A Developer-role key can upload builds but
   cannot create the app record.
3. Create the app record for `com.vorantx.vory`.

App Store Connect fields for that record:

| Field | Value |
|---|---|
| Name (30 char limit) | `Vory: Hermes Agent UI` |
| Bundle ID | `com.vorantx.vory` |
| SKU | `vory-ios` |
| Primary language | English (U.S.) |

The home screen name stays `Vory` via `CFBundleDisplayName`; iOS truncates anything longer. Only
the listing carries the descriptive form.

Everything after that is unattended. Apple occasionally introduces a new agreement that silently
blocks uploads until it is accepted, so an upload that suddenly fails on a previously working
setup is worth checking there first.

### Mock gateway

`Tools/mock-gateway/mock_gateway.py` is a protocol-faithful fake dashboard: the REST endpoints the
app reads plus the `/api/ws` JSON-RPC surface, including a scripted turn that streams
`message.delta` token by token, runs two `terminal` tool calls, asks for an approval and finishes
with `message.complete` and usage. It needs no AI provider, no API keys and makes no network calls,
so the whole chat surface can be developed and screenshotted offline.

```bash
python3 Tools/mock-gateway/mock_gateway.py --port 9119 --token mock-token
```

Then add a gateway in the app pointing at `http://127.0.0.1:9119` with that session token.
`ChatShowcaseUITests` drives a full conversation against it and saves screenshots of the streaming
state, the tool cards, the approval card, the finished transcript, the context sheet and the model
picker.

A prompt can steer the scripted turn: one that starts with `fail` ends with the "could not start
the assistant" error, and one that starts with `interrupt` ends with the gateway's own
"Operation interrupted." message (the card for a turn that was cut short). The mock also has two
projects and answers `session.workspace.move`, so moving a chat between projects can be tried;
a folder under `/nowhere` is refused the way a missing folder is.
