#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required. Install it: brew install jq" >&2
  exit 1
fi

link_kind() {
  local kind="$1"
  local src_dir="$REPO/$kind"
  local dest_dir="$CLAUDE_DIR/$kind"

  [ -d "$src_dir" ] || return 0
  mkdir -p "$dest_dir"

  for entry in "$src_dir"/* "$src_dir"/.[!.]*; do
    [ -e "$entry" ] || continue
    local name
    name="$(basename "$entry")"
    [ "$name" = ".gitkeep" ] && continue

    local target="$dest_dir/$name"

    if [ -L "$target" ]; then
      local current
      current="$(readlink "$target")"
      if [ "$current" = "$entry" ]; then
        continue
      fi
    fi

    if [ -e "$target" ] || [ -L "$target" ]; then
      local backup="$target.backup-$(date +%Y%m%d-%H%M%S)"
      mv "$target" "$backup"
      echo "Backed up $target -> $backup"
    fi

    ln -s "$entry" "$target"
    echo "Linked $target -> $entry"
  done

  # Prune stale symlinks: anything in dest_dir that points back into src_dir
  # but whose source no longer exists (e.g. the repo file was deleted/renamed).
  for target in "$dest_dir"/* "$dest_dir"/.[!.]*; do
    [ -L "$target" ] || continue
    local current
    current="$(readlink "$target")"
    case "$current" in
      "$src_dir"/*)
        if [ ! -e "$current" ]; then
          rm "$target"
          echo "Removed stale link $target -> $current"
        fi
        ;;
    esac
  done
}

link_file() {
  local name="$1"
  local src="$REPO/$name"
  local target="$CLAUDE_DIR/$name"

  [ -e "$src" ] || return 0
  mkdir -p "$CLAUDE_DIR"

  if [ -L "$target" ]; then
    local current
    current="$(readlink "$target")"
    if [ "$current" = "$src" ]; then
      return 0
    fi
  fi

  if [ -e "$target" ] || [ -L "$target" ]; then
    local backup="$target.backup-$(date +%Y%m%d-%H%M%S)"
    mv "$target" "$backup"
    echo "Backed up $target -> $backup"
  fi

  ln -s "$src" "$target"
  echo "Linked $target -> $src"
}

merge_settings() {
  local shared="$REPO/settings.shared.json"
  local local_file="$CLAUDE_DIR/settings.json"

  [ -f "$shared" ] || return 0
  mkdir -p "$CLAUDE_DIR"

  local current_json="{}"
  if [ -f "$local_file" ]; then
    current_json="$(cat "$local_file")"
  fi

  local merged
  merged="$(jq -n --argjson cur "$current_json" --slurpfile shared "$shared" '$cur * $shared[0]')"

  # Idempotency: only write if content changed.
  local existing_normalized=""
  if [ -f "$local_file" ]; then
    existing_normalized="$(jq -S . "$local_file" 2>/dev/null || echo "")"
  fi
  local merged_normalized
  merged_normalized="$(echo "$merged" | jq -S .)"

  if [ "$existing_normalized" != "$merged_normalized" ]; then
    local tmp
    tmp="$(mktemp)"
    echo "$merged" | jq . > "$tmp"
    mv "$tmp" "$local_file"
    echo "Merged settings.shared.json into $local_file"
  fi
}

link_kind skills
link_kind agents
link_kind commands
link_kind hooks
link_kind scripts
link_file statusline-command.sh
merge_settings

echo "Done."
