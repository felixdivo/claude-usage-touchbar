# Security

This project reads an OAuth token out of your login keychain. That deserves a
precise account rather than a reassuring one, so this document describes what
the code actually does and points at the lines that do it. If any claim here
does not match the source, that is a bug — please open an issue.

## What is read, and by what

`~/bin/claude-touchbar.sh` runs:

```sh
security find-generic-password -s 'Claude Code-credentials' -a "$USER" -w
```

That is Apple's `/usr/bin/security` reading the keychain item **Claude Code
created when you signed in**. This project creates no keychain item of its own
and asks for no new access. On most machines `/usr/bin/security` is already a
trusted application on that item, so no dialog appears; if one does, it will
name `security`.

`-w` returns the whole credential JSON, `refreshToken` included, into a
shell variable. Only `claudeAiOauth.accessToken` and `claudeAiOauth.expiresAt`
are parsed out of it, and the variable is `unset` straight after, on every
branch.

Note what that ACL means: `/usr/bin/security` hands this token to *any*
process running as you, without a prompt. That is Claude Code's and macOS's
posture, not something this project creates, but it is why anything that runs
code as you (see "Build time" below) has to be treated as able to read it.

## Where the token goes

Exactly one place — the `Authorization` header of a single GET request:

```
GET https://api.anthropic.com/api/oauth/usage
```

Handling, in order:

1. The token lives in a shell variable for the duration of one request.
2. It reaches `curl` through **stdin** (`-H @-`), never as an argument — so it
   does not appear in `ps`, in your shell history, or in any process listing.
3. `unset tok` immediately after the request.
4. It is never written to a file, never logged, never printed, never copied to
   the clipboard, and never passed to a child process's environment.

There is no telemetry, no analytics, no crash reporting, and no second
network destination. `api.anthropic.com` is the only host this project
contacts at runtime. You can confirm that yourself:

```sh
grep -oE 'https?://[^ "]+' ~/bin/claude-touchbar.sh
```

## What the GUI process can do

Nothing, with respect to your credentials. `ClaudeTouchBar.app`:

- never links `Security.framework` and never calls any keychain API
- opens no sockets — it has no networking code at all
- spawns exactly one subprocess: `/bin/bash -lc ~/bin/claude-touchbar.sh --raw`
- parses nine whitespace-separated numbers and strings from that output

The split exists so that the component with credential and network access is
around 100 lines of shell you can audit in a sitting, rather than a compiled
binary you have to take on trust.

## The disk-cache hazard, and why it is not present here

A prior tool that inspired this one used `NSURLSession.sharedSession` for the
same request. macOS caches responses for the shared session on disk, and the
cache retains request headers — so the full bearer token was written in plain
text to `~/Library/Caches/<bundle-id>/Cache.db-wal` with mode `0644`, readable
by any process running as that user, no prompt required. The application code
itself never wrote a file; the framework did it.

This project uses `curl` from a shell script, which has no such cache. The GUI
process performs no requests at all, so the failure mode cannot occur. If you
ever port the request into the app, use `ephemeralSessionConfiguration` and set
`URLCache` to `nil`.

That earlier tool's own SECURITY.md stated the token was "kept in memory only".
It was not. Verify claims like this against the code — including the ones on
this page.

## What is cached

`~/Library/Caches/local.claude-touchbar/usage`, in a directory the script
creates as mode `0700` and refuses to use if it is a symlink or not owned by
you, containing seven whitespace-separated values:

```
<5h%> <7d%> <resetMinutes> <weeklyResetMinutes> <scopedPct> <scopedName> <unixTimestamp>
```

Percentages, a model name and a timestamp. No token, no identifier.
Delete it whenever you like; it is rebuilt within a minute.

Earlier versions used `/tmp/.claude-usage-$UID`. A predictable name in a
world-writable directory let another local account pre-create the file, and
since its fields reach bash arithmetic, where `a[$(cmd)]` is executed, that
was code execution as you. `read_cache` now also refuses any field that is
not a plain integer, and `tools/test.sh` checks both payloads.

## Auto-refreshing an expired token

When the token is expired, `claude-touchbar.sh` runs:

```sh
claude --model haiku --effort low --strict-mcp-config \
  --no-session-persistence --max-budget-usd 0.02 -p hi
```

launchd starts the app with `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, which does
not include Homebrew, so the binary is located by checking `command -v` and
then a fixed list of standard install paths (`/opt/homebrew/bin`,
`/usr/local/bin`, `~/.local/bin`, `~/.claude/local`, `~/bin`). Only an
executable at one of those paths is ever run; nothing is downloaded, and no
directory is searched recursively. If none exists, no subprocess is started
and the widget says `claude -p hi` rather than claiming to refresh.

in the background, **once per expiry episode**, marked by an empty file
`~/Library/Caches/local.claude-touchbar/refresh`. For 180 seconds after the
launch the widget says "refreshing". If the token is still expired after that,
it says to run `/login` and launches nothing more until a reading succeeds
again (which deletes the marker). Earlier versions relaunched every 180 seconds
indefinitely.

A failed keychain read (no item, locked keychain, unexpected JSON) is reported
as `stale`, not `expired`, so it never triggers a refresh.

The CLI runs from the cache directory with `--setting-sources project,local`,
so no project `CLAUDE.md` or settings are picked up, and your user-level hooks
and plugins do not run in this background process. *Unverified:* that the
refresh still succeeds with that flag on every CLI version. If it does not, the
widget falls back to telling you to run `/login`. Your user `~/.claude/CLAUDE.md`
is still loaded and sent with the "hi", as in any session. Each refresh is a
real request: assume it can open a new 5-hour usage window.

Turn it off entirely with
`defaults write local.claude-touchbar AutoRefresh -bool NO`.

This is the same `claude` binary you already run and trust, not code from
this project reaching out on its own. It is launched, not linked: this
script has no more access to its internals than you do typing the command
yourself. The flags only trim what that session does — cheapest model,
lowest effort, no MCP servers, no session saved to disk, a hard spend cap —
they grant no new access. The CLI reads `refreshToken` to do this (this
script still never does), and makes whatever network calls the `claude` CLI
itself makes to authenticate; auditing *that* is Anthropic's CLI, not this
project, and outside this document's scope. `api.anthropic.com` remains the
only host `claude-touchbar.sh`'s own code (the `curl` call above) contacts.

## Build time: `make assets`

`tools/extract-assets.py` downloads JavaScript from claudepix.vercel.app, a
third-party site, and has to *execute* it to compute the pose grids. Run
unconfined, that code could do anything you can, including reading the token
above. It now runs under two independent layers:

- Node's permission model (`--permission`, Node >= 22): file reads only
  inside the temp dir, no file writes, no `child_process`, no workers, no
  native addons.
- `sandbox-exec`: no network, no writes outside the temp dir, and node is the
  only executable it may start.

Its output is untrusted too, because it is written into `clawd_presets.h` and
compiled. Every value is type- and range-checked first (`hold` 1-60000, grid
20x20 of ints 0-15, palette `#rrggbb`). The script fails unless all 13 clips
extract, because `main.m` addresses them by index.

## Private API

The app calls `+[NSTouchBar presentSystemModalTouchBar:placement:systemTrayItemIdentifier:]`
and `DFRSystemModalShowsCloseBoxWhenFrontMost` from `DFRFoundation.framework`.
These are undocumented, and no public alternative exists — a Control Strip item
is a fixed narrow slot with no sizing API in either the public headers or the
private method table.

The call is guarded with `respondsToSelector:`; if a future macOS removes it,
the app logs and exits instead of crashing. This is also why the app can never
be distributed through the App Store.

No entitlements are requested and ad-hoc signing is sufficient. Nothing here
needs Full Disk Access, Screen Recording, or any other TCC permission — with
one exception you should know about before you install it.

## The Escape key, and the one permission that may be asked for

Presenting a Touch Bar covers the system Escape key, so the app draws a
replacement. Pressing it synthesises a real key event:

```objc
CGEventPost(kCGHIDEventTap, CGEventCreateKeyboardEvent(NULL, 53, true));
```

**Posting synthetic key events is exactly what the Accessibility permission
governs.** On this machine the button works and macOS has not asked, but that
may be because of how the event is routed on a Touch Bar rather than a general
rule, and the behaviour has changed between macOS releases before. Treat it as:
if a permission dialog appears, it will be *Accessibility*, it will be caused by
pressing the Escape button, and declining it costs you only that button — the
usage readout does not depend on it.

An earlier version of this file claimed no permission could ever be requested.
That claim was written from intent rather than from reading this code path, and
it was the kind of unverified reassurance a security document should never
contain. If you find any other statement here that the source does not support,
please open an issue.

## Reporting

Open a GitHub issue. This is a personal project maintained on a best-effort
basis — if you need a guaranteed response window, this is not the right
dependency for you.
