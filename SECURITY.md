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

From the returned JSON only `claudeAiOauth.accessToken` and
`claudeAiOauth.expiresAt` are used. `refreshToken` is never read.

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
- parses six whitespace-separated numbers and strings from that output

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

`/tmp/.claude-usage-$UID`, mode `0600`, containing six whitespace-separated
values:

```
<5h%> <7d%> <resetMinutes> <scopedPct> <scopedName> <unixTimestamp>
```

Percentages and a timestamp. No token, no identifier, nothing about you.
Delete it whenever you like; it is rebuilt within a minute.

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

in the background, throttled to once every 180 seconds by an empty marker
file at `/tmp/.claude-touchbar-refresh-$UID` (mode inherited from `umask`,
contents just a timestamp via mtime — nothing to read from it).

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
