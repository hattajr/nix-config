#!/usr/bin/env bash
# Compact one-line status: prompt | model | ctx used/total (pct) | cost | 5h limit | weekly limit
input=$(cat)

model=$(echo "$input" | jq -r '.model.display_name // "?"')
# total_input_tokens is cumulative across the session, so prefer what the last request actually sent
used=$(echo "$input" | jq -r '
  .context_window.current_usage as $u
  | if $u then ($u.input_tokens // 0) + ($u.cache_creation_input_tokens // 0) + ($u.cache_read_input_tokens // 0)
    else empty end')
size=$(echo "$input" | jq -r '.context_window.context_window_size // empty')
pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')
five=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
week=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')

# Render token counts as 12.3k / 1.0M
fmt() {
  awk -v n="$1" 'BEGIN {
    if (n >= 1000000) printf "%.1fM", n / 1000000;
    else if (n >= 1000) printf "%.1fk", n / 1000;
    else printf "%d", n;
  }'
}

# Prompt part mirrors the zsh robbyrussell PROMPT: user@host ➜ dir git:(branch) ✗
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd')
dir=$(echo "$cwd" | sed "s|^$HOME|~|")
git_part=''
if branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null ||
  git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null); then
  dirty=''
  [ -n "$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)" ] && dirty=$(printf ' \033[33m✗\033[0m')
  git_part=$(printf ' \033[1;34mgit:(\033[0;31m%s\033[1;34m)\033[0m%s' "$branch" "$dirty")
fi
prompt=$(printf '\033[32m%s@%s\033[0m \033[36m➜\033[0m  %s%s' "$(whoami)" "$(hostname -s)" "$dir" "$git_part")

out="$prompt | $(printf '\033[36m%s\033[0m' "$model")"

if [ -n "$size" ]; then
  u=$(fmt "${used:-0}")
  s=$(fmt "$size")
  # Fall back to computing the percentage when Claude Code does not supply one
  [ -z "$pct" ] && pct=$(awk -v u="${used:-0}" -v s="$size" 'BEGIN { print (s > 0) ? u * 100 / s : 0 }')
  p=$(printf '%.0f' "$pct")
  # Color by pressure: green < 50, yellow < 80, red otherwise
  if [ "$p" -ge 80 ]; then c='31'; elif [ "$p" -ge 50 ]; then c='33'; else c='32'; fi
  out="$out | $(printf '\033[%sm%s/%s (%s%%)\033[0m' "$c" "$u" "$s" "$p")"
fi

[ -n "$cost" ] && out="$out | $(printf '$%.2f' "$cost")"
[ -n "$five" ] && out="$out | $(printf '5h: %.0f%%' "$five")"
[ -n "$week" ] && out="$out | $(printf '7d: %.0f%%' "$week")"

printf '%s' "$out"
