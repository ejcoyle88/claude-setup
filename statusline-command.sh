#!/bin/sh
input=$(cat)
cwd=$(echo "$input" | jq -r '.cwd')

# Model name (magenta)
model=$(echo "$input" | jq -r '.model.display_name // empty')

# Git branch (yellow) — cheap, skips silently when not in a repo
branch=$(git -C "$cwd" branch --show-current 2>/dev/null)

# Context window usage (color-coded: green <50%, yellow 50-80%, red >80%)
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')

# Build the output
# user@host:cwd in original colors
printf "\033[01;32m%s@%s\033[00m:\033[01;34m%s\033[00m" "$(whoami)" "$(hostname -s)" "$cwd"

# Model segment
if [ -n "$model" ]; then
  printf " \033[00;35m%s\033[00m" "$model"
fi

# Branch segment
if [ -n "$branch" ]; then
  printf " \033[00;33m(%s)\033[00m" "$branch"
fi

# Context usage segment
if [ -n "$used_pct" ]; then
  used_int=$(printf '%.0f' "$used_pct")
  if [ "$used_int" -ge 80 ]; then
    ctx_color="\033[01;31m"   # bold red
  elif [ "$used_int" -ge 50 ]; then
    ctx_color="\033[00;33m"   # yellow
  else
    ctx_color="\033[00;32m"   # green
  fi
  printf " ${ctx_color}ctx:%d%%\033[00m" "$used_int"
fi
