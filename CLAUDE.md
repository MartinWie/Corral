# Corral

macOS session orchestrator for Claude Code / OpenCode / PI on embedded libghostty. README.md is the
public overview (keep it short); behavior details, perf budgets and layout are in docs/internals.md. Public repo (github.com/MartinWie/Corral); releases and updates go through
GitHub Releases.

Privacy rule: nothing committed or shipped may identify the author. No real names, emails, home paths,
host names, employer, ticket keys or work project names, in code, test fixtures, docs, assets (strip
image metadata) or build output. `scripts/leak-scan.py` checks shipped files; extra needles live in
`~/.config/corral/leak-needles`, never in the repo.

## Build & test

- CLT only, no Xcode. `scripts/test.sh` (adds the swift-testing plugin path the CLT miss),
  `scripts/bundle.sh [--install]`.
- libghostty: `scripts/build-ghostty.sh` → `vendor/ghostty-out` (gitignored). Pinned Ghostty
  v1.4.0 needs Zig 0.17.1; the script downloads it into `vendor/` and never touches brew zig
  (a different version).
- `patches/ghostty-corral.patch`: runtime Metal shader compile (`newLibraryWithSource`) + plain
  static lib install + no forced `wait-after-command` for surfaces with a command (embedded.zig;
  without it a direct-launched session stays open as "Process exited" after `exit`).
  Regenerate with `git -C vendor/ghostty diff > patches/ghostty-corral.patch`.
- Package.swift drops the app target when `libghostty.a` is missing, so core tests always build.
  SwiftPM caches manifest evaluation: building the app needs `--manifest-cache none`
  (bundle.sh does it), else a build from before libghostty existed hides the target.
- Never pipe `swift test` / `swift build` output (masks exit code); redirect to a file.
- libghostty is built `-Di18n=false -Dsentry=false` (no LGPL gettext, no crash reporter in Ghostty's
  folders). Ghostty still bundles libintl in the archive on Apple; the linker drops it while nothing
  calls it: check `nm dist/Corral.app/Contents/MacOS/Corral | grep libintl` stays empty after a bump.
  After changing Ghostty or its options, rerun `scripts/notices.py` (license texts from Zig's cache);
  `--release` runs `notices.py --check` on the binary: fails on libintl/Sentry, on a known library
  family without a notice (FAMILIES in the script: add new ones there), on a stripped binary, and when
  THIRD_PARTY_NOTICES.txt is stale.
- A copy of the repo for isolated test runs needs `vendor/ghostty/include` too (GhosttyKit's shim
  includes `ghostty.h` from there), not only `vendor/ghostty-out`.
- Corral loads Ghostty's default config files only when one exists (Ghostty otherwise writes a template
  into Application Support). Fixes that must beat the user's includes go in `GhosttyDefaults.lateConfig`
  (loaded after `config-file` includes), e.g. ssh-env/ssh-terminfo off.
- Signing: the Developer ID from the keychain (detected, never written into the repo; the user chose
  it knowing the certificate shows the legal name), with hardened runtime + `Corral.entitlements`;
  `--release` requires it and adds a secure timestamp. Without one: the self-signed "Corral Local
  Signing" (`scripts/make-signing-identity.sh`, own keychain via `scripts/signing-keychain.sh`, since a
  key in the login keychain made codesign prompt; no hardened runtime, as library validation would
  reject Sparkle without a team ID), else ad hoc. Sparkle's XPC services are removed (sandbox only).
- Releases: `scripts/release.sh` (clean tree, HEAD pushed to main, new VERSION,
  `release-notes/<version>.md`; checks the Sparkle key and notary credentials first): tests →
  `bundle.sh --release` (notices check, `strip -S -x` since debug symbols hold absolute paths, dSYM
  kept as `dist/Corral-<version>.dSYM`, leak scan before signing) → notarize + staple the app → zip
  via `ditto --noextattr` → DMG (app + Applications link, signed, notarized, stapled) → `sign_update
  --account corral` → `dist/appcast.xml` (one item) → `gh release create` with DMG, zip, appcast.
  Feed: `releases/latest/download/appcast.xml` (latest non-prerelease). Build number = commit count,
  so it only grows on main. Notary credentials: `APPLE_ID`/`TEAM_ID`/`NOTARY_PASSWORD` env, else a
  notarytool keychain profile (`CORRAL_NOTARY_PROFILE`). `CORRAL_DIST=<dir>` builds there instead of
  `dist/` (bundle.sh starts with `rm -rf` of the app: never under a running `dist/Corral.app`).
- Sparkle EdDSA private key: login keychain, account `corral` (not Desko's default `ed25519`); back up
  with `generate_keys --account corral -x <file>`. Public key: `Resources/app/sparkle-public-key`.
  Tools: `scripts/sparkle-tools.sh` (downloads the version in Package.resolved, checksum pinned there).
- Icon: `swift scripts/make-icon.swift [new-art.png]` → `Resources/app/AppIcon.icns` from
  `assets/icon-art.png` (new art is re-encoded first, which drops C2PA/EXIF chunks).

- `scripts/coverage.sh` gate ≥ 90% (CorralCore + CorralKit). `scripts/perf.sh` = release perf
  budgets, run serially in isolation; budgets only enforce with CORRAL_PERF=1 because parallel
  suites share the main thread. Tests must never put UI on screen: sheets/panels go through
  `Presenter` (tests override it), never call `showWindow`/`present`.

## Architecture rules

- Targets: CorralCore (no AppKit) → CorralKit (AppKit, terminal-agnostic via `TerminalSurface`) →
  Corral (libghostty glue only). Keep logic out of Corral so it stays testable.
- Updates: `AppUpdater` (CorralKit protocol; menu item and Settings › General › Updates exist only
  with one) backed by `SparkleUpdater` in the Corral target. Sparkle is a dependency of the app target
  only, so core/kit tests resolve no packages. Bench runs get no updater. Updates always prompt:
  `SUAllowsAutomaticUpdates` false (no silent installs, no checkbox offering them); daily checks on.
- Agents offered: `SessionManager.installedAgents` (`env.agentInstalled`: command on the login shell's
  PATH or fallback dirs, or config folder; refreshed on app activation and when Settings opens). Hooks
  are offered by the stricter `agentPresent` (config folder: the agent has run here). New-session items
  stay in the menu, hidden and disabled (`MainWindowController.validateMenuItem`); `ShortcutStore.register`
  runs before they are hidden, so Settings › Shortcuts lists them greyed out.
- Claude session ids: new Claude sessions run `claude --session-id <uuid>` and save it at once, so they
  resume without hooks. Restoring or reopening one whose conversation was never written starts fresh
  under the same id (`relaunch`). At start the index opens before restoring, and id-less Claude records
  take the id of the only conversation with their title (`recoverSessionIds`).
- ⌘W ("Close Session") with another window in front goes through `FrontWindow.close`: that window
  closes (panels without a close button cancel), a sheet beeps; never the session behind it.
- Background commands: a Claude turn end (Stop, or the idle notice) while the agent process still has
  children started from Claude's shell snapshot (`ProcessInspector.claudeBackgroundShells`: the Bash tool's
  background commands; foreground ones end before the turn) is held: the session reads working
  ("Background command"), nothing is announced, the exits are watched with kqueue (`ProcessExitWatch`, no
  polling). Any other hook ends the hold; when the commands are gone and Claude stays quiet for
  `backgroundGrace` the held end applies.
- Removing hooks (Settings › Agents › Remove): `Integrations.uninstall*` take out only Corral's hook
  commands (settings.json backed up, unknown shapes refused) and only plugin files whose first line is
  Corral's. `AppSettings.hooksRemoved` keeps the sidebar banner from offering them again; installing
  clears it.
- One instance per support folder: a second Corral brings the first forward and quits
  (`AppDelegate.otherInstance`); `CORRAL_SUPPORT_DIR` exempts tests and benches.
- corral-hook is C on purpose: Claude runs hooks synchronously (and `async: true` would let
  PostToolUse race past Stop). Keep it parse-free; event name comes from argv.
- Index work drains autorelease pools per chunk/file (JSONSerialization); without them a first
  index held ~300 MB.

- Status is event-driven only: hooks over the Unix socket, Ghostty actions, FSEvents. No polling
  timers (the 30 s sidebar timer only re-renders relative times). One bounded exception: the
  launch probe (`SessionManager.scheduleLaunchProbe`) reads a launching terminal's visible screen
  (viewport only, never the scrollback) every 100 ms, only while some session is launching, at most
  4 s per fresh start / 8 s per resume, as a one-shot re-armed per tick. Resumes and attaches replay
  their transcript, so they reveal once the screen is unchanged for 2 probes; hooks and titles only
  reveal fresh starts. App start restores the selected session first, then agent resumes
  `restoreConcurrency` (2) at a time; a restored terminal is placed in the window at once (a resume
  at the default size would redraw everything when first shown). libghostty's Metal renderer has no output callback, so first output can't be observed
  otherwise. Never widen it into a general poll.
- Direct agent launch (`AgentLaunch`, zsh login shells only): the terminal command is
  `zsh -fc '<outer>'`; outer runs `zsh -lic '<agent>…'`, reports, then `exec zsh -l`.
  Invariants: the report + exec live in the non-interactive outer shell (an interactive `zsh -c`
  aborts its whole list on Ctrl-C, during rc loading or when SIGINT kills the agent); the outer
  shell catches INT/QUIT/TSTP with a trap (never `''`: ignored signals would be inherited by the
  agent); the agent sits at the top level of the inner script, never in `{ }`/a function (a job
  suspended there is forked out of reach of `fg`), followed by the resume-stopped-jobs loop; the exit
  report goes through `$CORRAL_HOOK` as `CorralAgentExit {"exit":N}` (the reducer maps it like a
  foreground-process exit and never sets `hooksSeen`); no ZDOTDIR handling: `-f` leaves Ghostty's
  injected environment untouched for the follow-up shell. The inner shell never prompts, so
  anything rc files defer to the first prompt never finishes: gitstatus (p10k) leaves a zsh
  blocked on its FIFO per launch unless the inner zshexit hook `__corral_reap` stops it
  (`gitstatus_stop*`, main shell only). The app bench's `agent_launch_orphans` must stay 0. `AgentLaunchTests` runs the scripts for
  real on a pty (Ctrl-C/Ctrl-Z typed); keep them green.
- `StatusReducer` (CorralCore) is the single place that maps signals to `Activity`; keep it pure
  and unit-tested. Hooks win over terminal heuristics (`hooksSeen`).
- Agent integrations must be no-ops outside Corral (check `CORRAL_SURFACE_ID` / `CORRAL_HOOK`)
  and must never block or print (Claude hook stdout is interpreted).
- `TerminalView` input handling mirrors Ghostty's `SurfaceView_AppKit.swift`
  (vendor/ghostty/macos/Sources/Ghostty/Surface View). When Ghostty changes key/IME handling,
  port from there instead of inventing.
- Display id: libghostty's display link (vsync) is bound to a display, and a hidden surface
  (`setVisible(false)`) releases its frame and draws again only through that link. `TerminalView`
  re-sends the id on window screen changes (as Ghostty's SurfaceView) and whenever it becomes
  visible; a link left on a display that went away keeps the terminal blank.
- libghostty C strings in action callbacks are only valid during the callback; copy them in
  `GhosttyRuntime.map`.
- Workspace (tree/records) is a value type; mutate through `Workspace` methods so tests cover it.
- Shortcuts: the main menu is the single source. Never hardcode a key in a hint; read it with
  `KeyHint` and refresh on `.corralShortcutsChanged` (`ShortcutStore` rewrites the menu's key
  equivalents when the user customizes them). New menu items are customizable automatically; standard
  macOS ones go in `ShortcutStore.fixed`. The menu is built before the terminals so the first Ghostty
  config already carries the custom shortcuts' unbinds (`GhosttyDefaults.unbinds`).
- Compaction: Claude compacts idle sessions ~55 min after a turn (PreCompact trigger auto/idle +
  SessionStart source compact, no Stop). Only mid-turn compaction or `/compact` may read as working;
  the reducer restores the pre-compaction state (`LiveStatus.compactFrom`). Never map PreCompact to
  `.working` unconditionally (finished sessions then spin forever and hold keep-awake).
- Cards: `paneLayouts[holder]` leaves are the holder, other sessions shown side by side, and shell
  panes. Change layouts only through `SessionManager.setLayout` (keeps `layoutOwnerOf` and the saved
  `Workspace.splits` in step). One level: showing a session beside another merges it into that card;
  a holder that leaves or closes hands the card (and its panes) to the next session on it. The
  container builds one split host per holder and skips sessions living inside one (`hostId`).
- Notification Allow/Deny type into the session (`text:1` / Esc via `perform(binding:)`) only while
  the prompt the note was posted for is still up (`SessionManager.promptToken`, Claude only).
- Environment from the login shell: `ShellEnvironment.value(key)` (PATH, CLAUDE_CONFIG_DIR, XDG_*),
  never `ProcessInfo...environment` directly for those, and never `setenv` them: terminals inherit
  Corral's environment and must get their values from their own login shell. The probe runs the shell
  in its own session (posix_spawn SETSID; an interactive zsh with a controlling tty stops on SIGTTOU),
  kills its process group on timeout; tests pass HOME/ZDOTDIR so the machine's rc files never run.
- ⌥⌘ arrows: `SessionManager.moveFocus` → `PaneLayout.neighbor(of:toward:boxes:prefer:)` with the
  container's real frames (`cardBoxes`), falling back to even halves; up/down off the card go to the
  previous/next shown session. Go-menu items, so they reach the menu before Ghostty's goto_split.
- Notifications go through `ManagerEnvironment.notifier` (tests record); kinds and sounds live in
  `AppSettings.notifications`; `SessionManager.notificationKind` is the pure rule. Permission is asked
  lazily, never at launch.
- Keep awake (`SessionManager.updateKeepAwake`) is event-driven like status: re-evaluated on every
  status/background/structure emit, holds one IOKit idle-sleep assertion while an agent session is
  `.working` or a background job is; tests swap `ManagerEnvironment.power` for a fake. "Keep the
  display on too" makes it a display-sleep assertion (that also blocks idle sleep); a type can't be
  changed, so toggling it while held releases and takes a new one.
- Agent names (Claude's `/rename` writes `custom-title` to the transcript, PI's session name; not
  Claude's `agent-name`, which it writes on its own from the AI title): the index keeps them in
  `sessions.title_agent`, apart from `title_custom` (which Corral's own rename also writes). After every
  index refresh `SessionManager.syncAgentNames` copies them to `SessionRecord.agentName` via
  `Workspace.setAgentName`: shown below `customName`. The first sync only records the conversation's
  name ("" for none, nil = not synced; a new conversation id resets it to nil); a change after that is
  a rename inside the agent and clears `customName` (the latest rename wins). Claude rewrites the same
  name every turn: no change. Indexes from before the column get it filled once
  (`TranscriptIndexer.backfillAgentNames`, meta flag `agent_names`) before the first refresh, so that
  first sync sees names given earlier.
- Sidebar rows: AppKit slides row views on every incremental outline change (insert, remove,
  `moveItem`, expand/collapse), whatever the animation context says, and a slide needs a display to
  finish. One that stalls (displays asleep, window hidden) or gets cut short leaves row views between
  rows until `reloadData`, seen as closed rows covering the Closed header. So planned ops run only
  when `SidebarFX.canAnimate` (else `reload` falls back to a full reload, and a non-animated toggle
  rebuilds); `Motion.displaysAsleep` turns animations off while the displays sleep; and
  `healIfNeeded` (rows vs model, row views vs their rows) runs once structure updates settle
  (`scheduleSettleCheck`), on activation, on display wake and when the window shows again. Test
  windows are never on screen, so they stall animations like a sleeping display:
  `SidebarStressTests` relies on that.
- Settings rows: a wrapping caption must get its width from constraints (row/page), never from its
  text, and never set `preferredMaxLayoutWidth` during layout (the window then loops on constraint
  passes and AppKit throws). Scroll views must start below the transparent titlebar (else macOS 26
  adds its titlebar edge blur and snapshots render the page empty).

## Files

- State: `~/Library/Application Support/Corral/{state.json,index.sqlite,corral.sock}`.
- `CORRAL_SUPPORT_DIR` overrides that directory (tests / a second instance).
