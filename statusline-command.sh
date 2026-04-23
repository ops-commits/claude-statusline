#!/usr/bin/env bash
# Status line: context/1M | 5h% | 7d% ±delta | last 4 messages
set -f

input=$(cat)
if [ -z "$input" ]; then
  printf "Claude"
  exit 0
fi

NOW=$(date +%s)

# --- Extract all fields from input JSON in one jq call ---
eval "$(echo "$input" | jq -r '
  @sh "ctx_used=\(
    (.context_window.current_usage.input_tokens // 0)
    + (.context_window.current_usage.cache_creation_input_tokens // 0)
    + (.context_window.current_usage.cache_read_input_tokens // 0)
  )",
  @sh "ctx_size=\(.context_window.context_window_size // 0)",
  @sh "SID=\(.session_id // "")"
' 2>/dev/null)"

# --- Format token counts (pure bash, no awk) ---
fmt() {
  local n=$1
  if [ "$n" -ge 1000000 ]; then
    local m=$(( n / 1000000 ))
    local r=$(( (n % 1000000) / 100000 ))
    if [ "$r" -eq 0 ]; then printf "%dM" "$m"
    else printf "%d.%dM" "$m" "$r"; fi
  elif [ "$n" -ge 1000 ]; then
    printf "%dk" $(( n / 1000 ))
  else
    printf "%d" "$n"
  fi
}

ctx="$(fmt "${ctx_used:-0}")/$(fmt "${ctx_size:-0}")"

# --- Usage via OAuth API ---
# Cache file mtime = when data was last successfully fetched (data freshness).
# Attempt file mtime = when we last tried the API (throttle, not freshness).
# Backoff file = consecutive failure count (exponential backoff on errors).
#
# Per-install isolation: CLAUDE_CONFIG_DIR partitions Claude Code installs
# (e.g. `ccb` runs with CLAUDE_CONFIG_DIR=~/.claude-tech). Each install has its
# own OAuth token in a separate Keychain slot and must have its own cache files,
# or switching installs will serve the other account's stale usage numbers.
# Claude Code's Keychain-slot suffix is sha256(config_dir)[:8]; we mirror that.
CCD="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CCD="${CCD%/}"
CCD_HASH=$(printf '%s' "$CCD" | shasum -a 256 | cut -c1-8)

cache_file="/tmp/claude/statusline-usage-cache-${CCD_HASH}.json"
attempt_file="/tmp/claude/statusline-last-attempt-${CCD_HASH}"
backoff_file="/tmp/claude/statusline-backoff-${CCD_HASH}"
mkdir -p /tmp/claude

needs_refresh=true
usage_data=""
cache_age=9999

if [ -f "$cache_file" ]; then
  cache_mtime=$(stat -f %m "$cache_file" 2>/dev/null || echo 0)
  cache_age=$((NOW - cache_mtime))
  usage_data=$(cat "$cache_file" 2>/dev/null)
fi

# Compute refresh interval: 180s base, doubles on each consecutive failure (max 600s)
failures=0
[ -f "$backoff_file" ] && failures=$(cat "$backoff_file" 2>/dev/null)
[[ "$failures" =~ ^[0-9]+$ ]] || failures=0
if [ "$failures" -le 0 ]; then
  refresh_interval=180
elif [ "$failures" -eq 1 ]; then
  refresh_interval=300
else
  refresh_interval=600
fi

# Skip if cache is fresh enough (data is current, no need for API call)
if [ "$cache_age" -lt "$refresh_interval" ]; then
  needs_refresh=false
fi

# Also skip if we attempted recently (even if cache is old — respect backoff)
if $needs_refresh && [ -f "$attempt_file" ]; then
  attempt_mtime=$(stat -f %m "$attempt_file" 2>/dev/null || echo 0)
  if [ $(( NOW - attempt_mtime )) -lt "$refresh_interval" ]; then
    needs_refresh=false
  fi
fi

if $needs_refresh; then
  touch "$attempt_file" 2>/dev/null

  token=""
  expires_at=""

  if command -v security >/dev/null 2>&1; then
    # Default install uses the plain slot; non-default installs use a hashed suffix.
    if [ "$CCD" = "$HOME/.claude" ]; then
      keychain_slot="Claude Code-credentials"
    else
      keychain_slot="Claude Code-credentials-${CCD_HASH}"
    fi
    blob=$(security find-generic-password -s "$keychain_slot" -w 2>/dev/null)
    if [ -n "$blob" ]; then
      eval "$(echo "$blob" | jq -r '
        @sh "token=\(.claudeAiOauth.accessToken // "")",
        @sh "expires_at=\(.claudeAiOauth.expiresAt // "")"
      ' 2>/dev/null)"
    fi
  fi
  if [ -z "$token" ] || [ "$token" = "null" ]; then
    creds="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"
    if [ -f "$creds" ]; then
      eval "$(jq -r '
        @sh "token=\(.claudeAiOauth.accessToken // "")",
        @sh "expires_at=\(.claudeAiOauth.expiresAt // "")"
      ' "$creds" 2>/dev/null)"
    fi
  fi

  # Skip API call if token is expired (expiresAt is milliseconds since epoch).
  # Claude Code refreshes the token on next session start — don't waste rate limit.
  token_expired=false
  if [ -n "$expires_at" ] && [ "$expires_at" != "null" ]; then
    now_ms=$((NOW * 1000))
    [ "$now_ms" -ge "$expires_at" ] && token_expired=true
  fi

  if ! $token_expired && [ -n "$token" ] && [ "$token" != "null" ]; then
    resp=$(curl -s --max-time 5 \
      -H "Accept: application/json" \
      -H "Authorization: Bearer $token" \
      -H "anthropic-beta: oauth-2025-04-20" \
      "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
    if [ -n "$resp" ] && echo "$resp" | jq -e '.five_hour' >/dev/null 2>&1; then
      usage_data="$resp"
      echo "$resp" > "$cache_file"
      cache_age=0
      echo 0 > "$backoff_file"  # reset backoff on success
    else
      # API error (rate limit, timeout, etc.) — increment backoff
      echo $(( failures + 1 )) > "$backoff_file"
    fi
  fi
fi

# --- Format output ---
dim='\033[2m'
rst='\033[0m'
grn='\033[38;2;0;180;0m'
org='\033[38;2;255;160;60m'
red='\033[38;2;255;85;85m'

# (queue indicator removed — user preference)

delta_color() {
  local d=$1
  if [ "$d" -ge 15 ]; then echo "$red"
  elif [ "$d" -ge 4 ]; then echo "$org"
  elif [ "$d" -le -4 ]; then echo "$grn"
  else echo ""
  fi
}

iso_to_epoch() {
  # Extract YYYY-MM-DDTHH:MM:SS (19 chars), ignoring fractional seconds and timezone
  local s="${1:0:19}"
  local e
  e=$(env TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$s" +%s 2>/dev/null) || \
  e=$(date -d "$1" +%s 2>/dev/null) || return 1
  echo "$e"
}

# --- Line 1: stats ---
# Staleness: ? if data is >5 min old (API failures leave cache stale)
stale=""
if [ "$cache_age" -gt 300 ]; then
  stale="${dim}?${rst}"
fi

if [ -n "$usage_data" ]; then
  # Extract all usage fields in one jq call
  eval "$(echo "$usage_data" | jq -r '
    @sh "h5=\(.five_hour.utilization // 0 | floor)",
    @sh "d7=\(.seven_day.utilization // 0 | floor)",
    @sh "resets_at=\(.seven_day.resets_at // "")"
  ' 2>/dev/null)"

  if [ -n "$h5" ] && [ "$h5" != "null" ]; then
    par=""
    # Only show delta when data is fresh — stale d7 + current NOW = wrong delta
    if [ "$cache_age" -le 300 ] && [ -n "$resets_at" ] && [ "$resets_at" != "null" ] && [ "$resets_at" != "" ]; then
      reset_epoch=$(iso_to_epoch "$resets_at")
      if [ -n "$reset_epoch" ]; then
        window=$((7 * 86400))
        start_epoch=$((reset_epoch - window))
        elapsed=$((NOW - start_epoch))
        [ "$elapsed" -lt 0 ] && elapsed=0
        [ "$elapsed" -gt "$window" ] && elapsed=$window
        expected=$(( elapsed * 100 / window ))
        delta=$((d7 - expected))
        dc=$(delta_color "$delta")
        if [ "$delta" -ge 0 ]; then
          par=" ${dc}+${delta}%${rst}"
        else
          par=" ${dc}${delta}%${rst}"
        fi
      fi
    fi

    printf "%b\n" "${ctx} ${dim}|${rst} ${dim}5h${rst} ${h5}%${stale} ${dim}|${rst} ${dim}7d${rst} ${d7}%${par}${stale}"
  else
    printf "%b\n" "${ctx} ${dim}| 5h - | 7d -${rst}"
  fi
else
  printf "%b\n" "${ctx} ${dim}| 5h - | 7d -${rst}"
fi

# --- Lines 2-5: last 4 user messages (newest first, this session only) ---
LOG_FILE="$HOME/.claude/message-logs/${SID}.txt"
if [ -n "$SID" ] && [ -f "$LOG_FILE" ]; then
  # grep for valid log lines, take last 4, reverse, parse with bash (no sed)
  grep -E '^[0-9]{2}:[0-9]{2}:[0-9]{2} \[(sent|queued|dequeued)\]' "$LOG_FILE" 2>/dev/null \
    | tail -4 | tail -r | while IFS= read -r line; do
    rest="${line:9}"
    msg="${rest#*] }"
    [ -z "$msg" ] && continue
    # Compact: no timestamp, no ANSI (save every char for message text)
    if [ ${#msg} -gt 60 ]; then
      msg="${msg:0:57}..."
    fi
    echo "> ${msg}"
  done
fi

# --- Housekeeping (runs in background, doesn't block output) ---
{
  # Prune session logs older than 7 days (at most once per hour)
  PRUNE_STAMP="/tmp/claude/statusline-pruned"
  prune_mtime=0
  [ -f "$PRUNE_STAMP" ] && prune_mtime=$(stat -f %m "$PRUNE_STAMP" 2>/dev/null || echo 0)
  if [ $(( $(date +%s) - prune_mtime )) -gt 3600 ]; then
    find "$HOME/.claude/message-logs" -name "*.txt" -mtime +7 -delete 2>/dev/null
    find "$HOME/.claude/queues" -name "*.txt" -mtime +7 -delete 2>/dev/null
    touch "$PRUNE_STAMP" 2>/dev/null
  fi

  # Self-update: check once per day, compare hash, replace if changed
  SELF="${BASH_SOURCE[0]:-$0}"
  UPDATE_STAMP="/tmp/claude/statusline-update-checked"
  REMOTE_URL="https://raw.githubusercontent.com/ops-commits/claude-statusline/main/statusline-command.sh"
  update_mtime=0
  [ -f "$UPDATE_STAMP" ] && update_mtime=$(stat -f %m "$UPDATE_STAMP" 2>/dev/null || echo 0)
  if [ $(( $(date +%s) - update_mtime )) -gt 86400 ]; then
    touch "$UPDATE_STAMP" 2>/dev/null
    remote=$(curl -sfL --max-time 5 "$REMOTE_URL" 2>/dev/null)
    if [ -n "$remote" ]; then
      local_hash=$(shasum -a 256 "$SELF" 2>/dev/null | cut -d' ' -f1)
      remote_hash=$(printf '%s' "$remote" | shasum -a 256 2>/dev/null | cut -d' ' -f1)
      if [ "$local_hash" != "$remote_hash" ]; then
        printf '%s' "$remote" > "$SELF"
      fi
    fi
  fi
} &

exit 0
