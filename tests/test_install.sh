#!/usr/bin/env bash
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$REPO_ROOT/install.sh"

pass=0
fail=0
failed_tests=()

assert() {
  local desc="$1"
  local cond="$2"
  if eval "$cond"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    failed_tests+=("$desc: $cond")
    echo "  FAIL: $desc"
    echo "        condition: $cond"
  fi
}

# Portable stat helpers: GNU coreutils (Linux, Git Bash on Windows) first,
# then BSD stat (macOS) as a fallback.
stat_inode_mtime() {
  stat -c '%i %Y' "$1" 2>/dev/null || stat -f '%i %m' "$1"
}
stat_mtime() {
  stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1"
}

setup() {
  TMPDIR_TEST="$(mktemp -d)"
  export CLAUDE_DIR="$TMPDIR_TEST/.claude"
  mkdir -p "$CLAUDE_DIR"
}

teardown() {
  rm -rf "$TMPDIR_TEST"
  unset CLAUDE_DIR
}

run_test() {
  local name="$1"
  echo "TEST: $name"
  setup
  "$name"
  teardown
}

# --- Symlink tests ---

test_fresh_install_creates_symlinks() {
  bash "$INSTALL" >/dev/null

  assert "skills/angular-a11y is a symlink" \
    "[ -L '$CLAUDE_DIR/skills/angular-a11y' ]"
  assert "skills symlink points into the repo" \
    "[ \"\$(readlink '$CLAUDE_DIR/skills/angular-a11y')\" = '$REPO_ROOT/skills/angular-a11y' ]"
  assert "agents/csharp-developer.md is a symlink" \
    "[ -L '$CLAUDE_DIR/agents/csharp-developer.md' ]"
  assert "scripts/git-ro.sh is a symlink" \
    "[ -L '$CLAUDE_DIR/scripts/git-ro.sh' ]"
  assert "scripts symlink points into the repo" \
    "[ \"\$(readlink '$CLAUDE_DIR/scripts/git-ro.sh')\" = '$REPO_ROOT/scripts/git-ro.sh' ]"
  assert ".gitkeep is NOT linked" \
    "[ ! -e '$CLAUDE_DIR/skills/.gitkeep' ]"
}

test_idempotent_no_backups_on_second_run() {
  bash "$INSTALL" >/dev/null
  bash "$INSTALL" >/dev/null

  local backups
  backups="$(find "$CLAUDE_DIR" -name '*.backup-*' 2>/dev/null | wc -l | tr -d ' ')"
  assert "no backup files after two install runs" "[ '$backups' = '0' ]"
}

test_real_file_is_backed_up() {
  mkdir -p "$CLAUDE_DIR/skills"
  echo "user's own content" > "$CLAUDE_DIR/skills/angular-a11y"

  bash "$INSTALL" >/dev/null

  local backup_count
  backup_count="$(find "$CLAUDE_DIR/skills" -name 'angular-a11y.backup-*' | wc -l | tr -d ' ')"
  assert "backup file was created" "[ '$backup_count' = '1' ]"
  assert "target is now a symlink into the repo" \
    "[ -L '$CLAUDE_DIR/skills/angular-a11y' ]"
}

test_correct_existing_symlink_is_left_alone() {
  bash "$INSTALL" >/dev/null
  # Capture the symlink's inode and mtime, then run again and check unchanged
  local before
  before="$(stat_inode_mtime "$CLAUDE_DIR/skills/angular-a11y")"
  sleep 1
  bash "$INSTALL" >/dev/null
  local after
  after="$(stat_inode_mtime "$CLAUDE_DIR/skills/angular-a11y")"
  assert "stat probe returned a value" "[ -n '$before' ] && [ -n '$after' ]"
  assert "symlink unchanged on second install" "[ '$before' = '$after' ]"
}

test_settings_merge_shared_wins_on_conflict_and_keeps_unrelated_personal_keys() {
  cat > "$CLAUDE_DIR/settings.json" <<'EOF'
{
  "theme": "light",
  "personalOnlyKey": "keep-me",
  "enabledPlugins": {
    "old-plugin": true
  }
}
EOF

  bash "$INSTALL" >/dev/null

  local theme
  theme="$(jq -r '.theme' "$CLAUDE_DIR/settings.json")"
  assert "shared theme overrides personal theme" "[ '$theme' = 'dark' ]"

  local personal_only
  personal_only="$(jq -r '.personalOnlyKey' "$CLAUDE_DIR/settings.json")"
  assert "unrelated personal key is preserved" "[ '$personal_only' = 'keep-me' ]"

  local old_plugin
  old_plugin="$(jq -r '.enabledPlugins["old-plugin"]' "$CLAUDE_DIR/settings.json")"
  assert "personal plugin entry is preserved" "[ '$old_plugin' = 'true' ]"

  local has_shared
  has_shared="$(jq -r '.enabledPlugins["superpowers@claude-plugins-official"]' "$CLAUDE_DIR/settings.json")"
  assert "shared plugin is enabled" "[ '$has_shared' = 'true' ]"
}

test_settings_created_when_missing() {
  [ ! -f "$CLAUDE_DIR/settings.json" ]

  bash "$INSTALL" >/dev/null

  assert "settings.json exists after install" "[ -f '$CLAUDE_DIR/settings.json' ]"
  local plugin
  plugin="$(jq -r '.enabledPlugins["superpowers@claude-plugins-official"]' "$CLAUDE_DIR/settings.json")"
  assert "shared plugin is in fresh settings.json" "[ '$plugin' = 'true' ]"
}

test_settings_merge_is_idempotent() {
  cat > "$CLAUDE_DIR/settings.json" <<'EOF'
{ "theme": "dark" }
EOF
  bash "$INSTALL" >/dev/null
  local first_mtime
  first_mtime="$(stat_mtime "$CLAUDE_DIR/settings.json")"
  sleep 1
  bash "$INSTALL" >/dev/null
  local second_mtime
  second_mtime="$(stat_mtime "$CLAUDE_DIR/settings.json")"
  assert "stat probe returned a value" "[ -n '$first_mtime' ] && [ -n '$second_mtime' ]"
  assert "settings.json mtime unchanged on second install" "[ '$first_mtime' = '$second_mtime' ]"
}

run_test test_fresh_install_creates_symlinks
run_test test_idempotent_no_backups_on_second_run
run_test test_real_file_is_backed_up
run_test test_correct_existing_symlink_is_left_alone
run_test test_settings_merge_shared_wins_on_conflict_and_keeps_unrelated_personal_keys
run_test test_settings_created_when_missing
run_test test_settings_merge_is_idempotent

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
