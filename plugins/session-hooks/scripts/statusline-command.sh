#!/usr/bin/env bash
input=$(cat)

MODEL=$(echo "$input" | jq -r '.model.display_name // "Unknown"')
CTX=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
CTX_SIZE=$(echo "$input" | jq -r '.context_window.context_window_size // empty')
FIVE_H=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
WEEK=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
FIVE_H_RESET=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
WEEK_RESET=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

# Reasoning effort (low/medium/high/xhigh/…). The field may arrive as a plain
# string OR as an object like {"level":"high"} — normalize both to a scalar and
# strip any newline so the status line always stays on ONE line. Prefer a live
# value from the payload; fall back to what /effort persisted in settings.json.
effort_scalar='(.effort // .effortLevel // .output_style.effort) as $e
  | if   $e == null              then empty
    elif ($e | type) == "object" then ($e.level // $e.name // $e.id // empty)
    else ($e | tostring) end'
EFFORT=$(printf '%s' "$input" | jq -r "$effort_scalar" 2>/dev/null | tr -d '\n')
if [ -z "$EFFORT" ]; then
  SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
  [ -f "$SETTINGS" ] && EFFORT=$(jq -r "$effort_scalar" "$SETTINGS" 2>/dev/null | tr -d '\n')
fi

# Lookup true context window size for known models (defaults to empty if native/unknown)
get_model_context_size() {
  local m="${1##*/}"
  m="${m##*@cf/*/}"
  m=$(echo "$m" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
  case "$m" in
    glm-5.3|glm-5.2|qwen3.8-max|qwen3.7-max|qwen3.7-plus|qwen3.6-plus|deepseek-v4-pro|deepseek-v4-flash|minimax-m3|mimo-v2.5)
      echo 1000000 ;;
    kimi-k3|mimo-v2.5-pro|mimo-v2-pro)
      echo 1048576 ;;
    gpt-5.6-luna)
      echo 1050000 ;;
    grok-4.5)
      echo 500000 ;;
    qwen3.5-plus|kimi-k2.7-code|kimi-k2.6|kimi-k2.5|mimo-v2-omni)
      echo 262144 ;;
    hy3|hy3-preview)
      echo 256000 ;;
    glm-5.1|glm-5)
      echo 202752 ;;
    minimax-m2.7|minimax-m2.5)
      echo 204800 ;;
    *)
      echo "" ;;
  esac
}

# Humanize token counts: 1500 -> 1.5k, 1000000 -> 1M
humanize() {
  awk -v n="$1" 'BEGIN {
    if (n >= 1000000) {
      val = n / 1000000;
      if (val >= 0.99 && val <= 1.05) printf "1M";
      else if (val == int(val)) printf "%dM", val;
      else printf "%.1fM", val;
    } else if (n >= 1000) {
      val = n / 1000;
      if (val == int(val)) printf "%dk", val;
      else if (val >= 100) printf "%.0fk", val;
      else printf "%.1fk", val;
    } else {
      printf "%d", n;
    }
  }'
}

LIMITS=""
if [ -n "$CTX" ]; then
  MODEL_ID=$(echo "$input" | jq -r '.model.id // .model.display_name // empty')
  KNOWN_CTX_SIZE=$(get_model_context_size "${MODEL_ID:-$MODEL}")
  if [ -n "$KNOWN_CTX_SIZE" ] && [ "$KNOWN_CTX_SIZE" -ne "${CTX_SIZE:-0}" ]; then
    # Recalculate true used tokens and percentage when client reported default 200k
    if [ -n "$CTX_SIZE" ] && [ "$CTX_SIZE" -gt 0 ]; then
      USED_TOK=$(awk -v p="$CTX" -v s="$CTX_SIZE" 'BEGIN { printf "%d", (p/100)*s }')
      CTX=$(awk -v u="$USED_TOK" -v k="$KNOWN_CTX_SIZE" 'BEGIN { printf "%.1f", (u/k)*100 }')
    fi
    CTX_SIZE="$KNOWN_CTX_SIZE"
  elif [ -n "$CTX_SIZE" ]; then
    USED_TOK=$(awk -v p="$CTX" -v s="$CTX_SIZE" 'BEGIN { printf "%d", (p/100)*s }')
  fi

  CTX_SEG="ctx: $(printf '%.0f' "$CTX")%"
  if [ -n "$CTX_SIZE" ] && [ -n "$USED_TOK" ]; then
    CTX_SEG="$CTX_SEG ($(humanize "$USED_TOK")/$(humanize "$CTX_SIZE"))"
  fi
  LIMITS="$CTX_SEG"
fi

if [ -n "$FIVE_H" ]; then
  FIVE_H_SEG="5h: $(printf '%.0f' "$FIVE_H")%"
  if [ -n "$FIVE_H_RESET" ] && [ -z "${FIVE_H_RESET//[0-9]/}" ]; then
    RESET_TIME_FIVE=$(date -d "@$FIVE_H_RESET" +%H:%M 2>/dev/null)
    if [ -n "$RESET_TIME_FIVE" ]; then
      FIVE_H_SEG="$FIVE_H_SEG (resets $RESET_TIME_FIVE)"
    fi
  fi
  LIMITS="${LIMITS:+$LIMITS | }$FIVE_H_SEG"
fi

if [ -n "$WEEK" ]; then
  WEEK_SEG="7d: $(printf '%.0f' "$WEEK")%"
  if [ -n "$WEEK_RESET" ] && [ -z "${WEEK_RESET//[0-9]/}" ]; then
    RESET_TIME_WEEK=$(date -d "@$WEEK_RESET" '+%a %d %b %H:%M' 2>/dev/null)
    if [ -n "$RESET_TIME_WEEK" ]; then
      WEEK_SEG="$WEEK_SEG (resets $RESET_TIME_WEEK)"
    fi
  fi
  LIMITS="${LIMITS:+$LIMITS | }$WEEK_SEG"
fi

# Plan progress segment, in every project: a project's executable `.claude/statusline-extra` wins
# (for example a project that reads its own ledger); otherwise checkbox counts over the plan
# docs RESUME.md's `### Plan` section names, found and counted by hooks/lib/plan_docs.sh, the same
# code session start uses. Bounded to 2 s, first line only, so the status stays ONE line and never
# hangs. Owner, 2026-10-18: the line carries effort, context, 5h, 7d, cache and this segment, nothing else.
PROJECT_DIR=$(echo "$input" | jq -r '.workspace.project_dir // .workspace.current_dir // .cwd // empty')
PLAN_SEG=""
if [ -n "$PROJECT_DIR" ] && [ -d "$PROJECT_DIR" ]; then
  if [ -x "$PROJECT_DIR/.claude/statusline-extra" ]; then
    PLAN_SEG=$(timeout -k 1 2 "$PROJECT_DIR/.claude/statusline-extra" "$PROJECT_DIR" 2>/dev/null | head -1)
  elif [ -f "$PROJECT_DIR/RESUME.md" ] && [ -f "$HOME/.claude/hooks/lib/plan_docs.sh" ]; then
    # shellcheck source=hooks/lib/plan_docs.sh
    . "$HOME/.claude/hooks/lib/plan_docs.sh"
    PLAN_SEG=$(plan_status_segment "$PROJECT_DIR/RESUME.md" "$PROJECT_DIR")  # open first, over every listed doc
  fi
fi
# Prompt-cache state, from the payload's prompt_cache object (field names taken
# from a captured 2.1.289 payload, 2026-10-05: warm, caching_observed, ttl,
# expires_at, hit_ratio, ...). Nothing until caching has been observed.
CACHE_SEG=$(printf '%s' "$input" | jq -r '.prompt_cache // empty
  | if .caching_observed != true then empty
    elif .warm == true then "cache: warm \(((.hit_ratio // 0) * 100) | floor)%"
    else "cache: cold (idle past TTL)" end' 2>/dev/null)
[ -n "$CACHE_SEG" ] && LIMITS="${LIMITS:+$LIMITS | }$CACHE_SEG"

EXTRA="$PLAN_SEG"

if [ -n "$LIMITS" ]; then
  echo "[$MODEL${EFFORT:+ · $EFFORT}] $LIMITS${EXTRA:+ | $EXTRA}"
else
  echo "[$MODEL${EFFORT:+ · $EFFORT}] rate limits unavailable yet${EXTRA:+ | $EXTRA}"
fi
