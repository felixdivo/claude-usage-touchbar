#!/bin/bash
# Claude usage for the Touch Bar widget.
#
# Prints (--raw): "<5h%> <7d%> <resetMin> <resetMin7> <ageSec> <state> <scopedPct> <scopedName> <refresh>"
#   refresh: only meaningful when state is `expired` — the healthy path never
#            looks for the CLI, so it reports `manual` without having checked.
#            auto    — a refresh is under way and has not yet failed
#            manual  — it will not fix itself: no `claude` binary was found, or a
#                      refresh was already tried and the token is still expired
#                      (the refresh token is dead; only `/login` helps)
#   state: ok      — fresh reading from the API
#          stale   — API unreachable, showing the last good numbers
#          expired — the OAuth token has expired; a refresh has been triggered
#          none    — never had a reading
#
# The caller MUST distinguish these: an expired token used to look identical to
# a healthy one, because the cache kept serving its last value forever.
#
# The token is read via /usr/bin/security (already on the keychain item's ACL,
# so nothing prompts), goes into a curl header over stdin — never argv, a file,
# or a log — and is unset immediately after.
set -uo pipefail
umask 077

# Per-user cache, not /tmp: a predictable name in a world-writable directory
# lets another local account pre-create the file (spoofed numbers, symlink
# clobbering — and, since the fields reach $(( )), code execution as you).
CACHE_DIR="$HOME/Library/Caches/local.claude-touchbar"
mkdir -p "$CACHE_DIR" 2>/dev/null
if [ -L "$CACHE_DIR" ] || [ ! -O "$CACHE_DIR" ]; then
  echo "0 0 -1 -1 -1 none -1 - manual"; exit 0
fi
chmod 700 "$CACHE_DIR"
CACHE=$CACHE_DIR/usage                 # "5h 7d resetMin resetMin7 scopedPct scopedName epoch"
TTL=60

# An expired token fixes itself the moment the `claude` CLI runs at all — it
# holds the refresh token this script deliberately never reads (see
# SECURITY.md). So instead of telling you to run `claude -p hi` by hand, fire
# it off ourselves: smallest model, lowest effort, no MCP servers, no session
# saved — a few cents' worth of "hi" at most, and often free-tier haiku usage
# doesn't even touch the limits this widget is showing you.
REFRESH_LOCK=$CACHE_DIR/refresh       # exists once a refresh was launched; removed once a reading succeeds
REFRESH_COOLDOWN=180                   # how long a launched refresh counts as "under way"

REFRESH=manual                         # -> auto once a refresh is actually launched

# launchd starts the app with PATH=/usr/bin:/bin:/usr/sbin:/sbin, and `bash -lc`
# only extends that from /etc/paths — so a Homebrew or per-user install of the
# CLI is invisible here even though `claude` resolves fine in your terminal.
# Relying on `command -v` alone made try_refresh return silently and left the
# widget claiming "refreshing…" forever. Look in the known locations too.
find_claude() {
  local c
  c=$(command -v claude 2>/dev/null) && [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  for c in /opt/homebrew/bin/claude /usr/local/bin/claude \
           "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" \
           "$HOME/bin/claude"; do
    [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# The CLI can only refresh with a live refresh token. When that is dead too,
# `claude -p hi` fails and the token stays expired. So: exactly one launch per
# expiry episode. Relaunching every cooldown used to fire a real request every
# three minutes, forever, whenever the token stayed expired. If it has not
# worked once the cooldown is over, it will not, and only `/login` helps. The
# lock is removed as soon as a reading succeeds, which starts a new episode.
#
# Opt out entirely: defaults write local.claude-touchbar AutoRefresh -bool NO
try_refresh() {
  local cli age=0
  [ "$(defaults read local.claude-touchbar AutoRefresh 2>/dev/null)" = 0 ] && return
  cli=$(find_claude) || return          # no CLI anywhere: stay REFRESH=manual
  if [ ! -e "$REFRESH_LOCK" ]; then
    : > "$REFRESH_LOCK"
    # Backgrounded and redirected to /dev/null so it never inherits this
    # script's stdout — that pipe is what NSTask reads to end-of-file, and an
    # inherited fd would make the Touch Bar poll block on this child too.
    # Run from the cache dir so no project CLAUDE.md or settings are picked
    # up, and load only project/local settings (there are none there): your
    # user-level hooks and plugins stay out of a background process.
    ( cd "${REFRESH_LOCK%/*}" || exit
      "$cli" --model haiku --effort low --strict-mcp-config \
        --setting-sources project,local --no-session-persistence \
        --max-budget-usd 0.02 -p hi >/dev/null 2>&1 & )
  else
    age=$(( $(date +%s) - $(stat -f %m "$REFRESH_LOCK" 2>/dev/null || echo 0) ))
  fi
  [ "$age" -lt "$REFRESH_COOLDOWN" ] && REFRESH=auto
}

# /usr/bin/python3 ships with the Command Line Tools, which this project already
# requires to build — so there is no runtime dependency to install. An earlier
# version pointed at a hard-coded nvm path, which worked on exactly one machine.
PY=/usr/bin/python3
[ -x "$PY" ] || PY=$(command -v python3) || {
  echo "0 0 -1 -1 -1 none"; exit 0; }

read_cache() {                          # -> P5 P7 RESET RESET7 SP SN STAMP
  local v
  [ -f "$CACHE" ] && [ ! -L "$CACHE" ] || return 1
  read -r P5 P7 RESET RESET7 SP SN STAMP < "$CACHE" 2>/dev/null || :
  # These fields reach $(( )), and bash evaluates `a[$(cmd)]` found there, so
  # anything but a plain integer is refused rather than trusted.
  for v in "${P5:-}" "${P7:-}" "${RESET:-}" "${RESET7:-}" "${SP:-}" "${STAMP:-}"; do
    case "${v#-}" in
      ''|*[!0-9]*) P5=; P7=; RESET=-1; RESET7=-1; SP=-1; SN=-; STAMP=0; return 1 ;;
    esac
  done
  case "${SN:-}" in ''|*[!A-Za-z0-9._-]*) SN=- ;; esac
  [ -n "${P5:-}" ]
}

P5=; P7=; RESET=-1; RESET7=-1; SP=-1; SN=-; STAMP=0
read_cache || :
AGE=$(( $(date +%s) - ${STAMP:-0} ))

state=ok
if [ "${STAMP:-0}" -eq 0 ] || [ "$AGE" -ge "$TTL" ]; then
  cred=$(security find-generic-password -s 'Claude Code-credentials' -a "$USER" -w 2>/dev/null)

  # Check expiry locally first: it tells us *why* we failed instead of guessing
  # from an HTTP code, and saves a round trip on a token that cannot work.
  # A failed read (no item, locked keychain, unexpected JSON) is not an expired
  # token: reporting it as one used to trigger the refresh on every poll.
  expired=$(printf '%s' "$cred" | "$PY" -c 'import json,sys,time
try: print("1" if json.load(sys.stdin)["claudeAiOauth"]["expiresAt"] < time.time()*1000 else "0")
except Exception: print("err")')

  if [ "$expired" = "err" ]; then
    unset cred
    state=stale
  elif [ "$expired" = "1" ]; then
    unset cred                          # holds the refresh token too; drop it now
    state=expired
    try_refresh
  else
    tok=$(printf '%s' "$cred" | "$PY" -c 'import json,sys
try: sys.stdout.write(json.load(sys.stdin)["claudeAiOauth"]["accessToken"])
except Exception: pass')
    unset cred

    # -w '%{http_code}' so a 401 is never silently parsed as "no data".
    resp=$(printf 'Authorization: Bearer %s' "$tok" | curl -sS --max-time 6 -H @- \
      -H 'Accept: application/json' -H 'anthropic-beta: oauth-2025-04-20' \
      -w '\n%{http_code}' https://api.anthropic.com/api/oauth/usage 2>/dev/null)
    unset tok

    code=$(printf '%s' "$resp" | tail -1)
    if [ "$code" = "401" ] || [ "$code" = "403" ]; then
      state=expired
      try_refresh
    elif [ "$code" = "200" ]; then
      # SCALE: the API reports whole percentages (0-100) directly, and
      # limits[].percent confirms it. A previous version guessed the scale with
      # `v > 1 ? v : v*100`, which turned a real 1% into 100%. Never infer a
      # scale — read the field as the payload actually reports it.
      parsed=$(printf '%s' "$resp" | sed '$d' | "$PY" -c '
import json, sys, re, datetime
try: j = json.load(sys.stdin)
except Exception: sys.exit(0)

def pct(w):
    v = (w or {}).get("utilization")
    return round(v) if isinstance(v, (int, float)) else -1

p5, p7, sp, sn = pct(j.get("five_hour")), pct(j.get("seven_day")), -1, "-"

for l in j.get("limits") or []:
    v = l.get("percent")
    if not isinstance(v, (int, float)):
        continue
    k = l.get("kind")
    if k == "session":       p5 = round(v)
    elif k == "weekly_all":  p7 = round(v)
    elif k == "weekly_scoped":
        sp = round(v)
        nm = ((l.get("scope") or {}).get("model") or {}).get("display_name")
        if nm: sn = re.sub(r"[^A-Za-z0-9._-]", "", nm) or "-"

def reset_minutes(window):
    t = (window or {}).get("resets_at")
    if not t:
        return -1
    try:
        # fromisoformat only learned to accept a trailing Z in 3.11.
        d = datetime.datetime.fromisoformat(t.replace("Z", "+00:00"))
        return max(0, round((d - datetime.datetime.now(d.tzinfo)).total_seconds() / 60))
    except Exception:
        return -1

m = reset_minutes(j.get("five_hour"))
m7 = reset_minutes(j.get("seven_day"))

print(f"{p5} {p7} {m} {m7} {sp} {sn}")')
      case "$parsed" in
        ''|-1\ -1\ *) state=stale ;;
        *) printf '%s %s\n' "$parsed" "$(date +%s)" > "$CACHE"; chmod 600 "$CACHE"
           read_cache || :; AGE=0; state=ok; rm -f "$REFRESH_LOCK" ;;
      esac
    else
      state=stale                       # network/5xx — keep the last good numbers
    fi
  fi
fi

# A known cause beats "no data": report expired even with an empty cache,
# otherwise a first run on a dead token looks like a first run on a fresh one.
if [ -z "${P5:-}" ]; then
  [ "$state" = expired ] && { echo "0 0 -1 -1 -1 expired -1 - $REFRESH"; exit 0; }
  echo "0 0 -1 -1 -1 none -1 - $REFRESH"; exit 0
fi
[ "$state" = ok ] || AGE=$(( $(date +%s) - ${STAMP:-0} ))

case "${1:-}" in
  --raw) printf '%s %s %s %s %s %s %s %s %s\n' "$P5" "$P7" "$RESET" "$RESET7" "$AGE" "$state" "${SP:--1}" "${SN:--}" "$REFRESH" ;;
  *)
     case "$state" in
       expired) [ "$REFRESH" = auto ] \
                  && printf 'token expired — refreshing…   (last: 5h %s%%  7d %s%%)\n' "$P5" "$P7" \
                  || printf 'token expired — run claude, then /login   (last: 5h %s%%  7d %s%%)\n' "$P5" "$P7" ;;
       stale)   printf '5h %s%%  7d %s%%   (stale %dm)\n' "$P5" "$P7" $((AGE/60)) ;;
       *)       printf '5h %s%%  7d %s%%' "$P5" "$P7"
                [ "${SP:--1}" -gt 0 ] && printf '  %s %s%%' "${SN:--}" "$SP"
                printf '   reset %dh%02d' $((RESET/60)) $((RESET%60))
                [ "${RESET7:--1}" -ge 0 ] && \
                  printf ' / %dd%02dh' $((RESET7/1440)) $(((RESET7/60)%24))
                printf '\n' ;;
     esac ;;
esac
