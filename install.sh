#!/bin/bash
# ai-tooling installer — Linux, macOS, Git Bash.
# What-goes-where lives in harnesses.tsv; what-goes is discovered by
# globbing skills/ agents/ commands/. Spec:
# docs/superpowers/specs/2026-07-08-installer-design.md
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
HOME_DIR="${AI_TOOLING_HOME:-$HOME}"
TSV="$REPO_DIR/harnesses.tsv"
RECEIPT_DIR="$HOME_DIR/.agents"
RECEIPT="$RECEIPT_DIR/.ai-tooling-receipt"
RECEIPT_HEADER="# ai-tooling-receipt v1"

MODE=copy ACTION=install DRY=0 FORCE=0 STATUS=0

usage() {
  cat <<'EOF'
Usage: install.sh [--link] [--uninstall] [--dry-run] [--force]
  --link       symlink from this clone instead of copying
  --uninstall  remove everything a previous run installed
  --dry-run    print actions without performing them
  --force      claim destinations that exist but aren't ours
Exit codes: 0 ok, 1 error, 2 completed with skips.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --link) MODE=link ;;
    --uninstall) ACTION=uninstall ;;
    --dry-run) DRY=1 ;;
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown flag: $arg" >&2; usage >&2; exit 1 ;;
  esac
done

die()  { echo "error: $*" >&2; exit 1; }
note() { echo "$*"; }

case "$(uname -s)" in
  Darwin|MINGW*|MSYS*|CYGWIN*) CASE_FOLD=1 ;;
  *) CASE_FOLD=0 ;;
esac

fold() {
  if [ "$CASE_FOLD" = 1 ]; then
    printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]'
  else
    printf '%s\n' "$1"
  fi
}

expand_tilde() {
  case "$1" in
    "~")    printf '%s\n' "$HOME_DIR" ;;
    "~/"*)  printf '%s\n' "$HOME_DIR/${1#\~/}" ;;
    *)      printf '%s\n' "$1" ;;
  esac
}

all_dests() {
  local content detect dest
  while IFS=$'\t' read -r content detect dest; do
    case "$content" in ''|'#'*) continue ;; esac
    dest="${dest%$'\r'}"   # belt-and-braces vs CRLF checkouts
    [ -n "$detect" ] && [ -n "$dest" ] \
      || die "harnesses.tsv: malformed row: '$content' (need 3 tab-separated fields)"
    printf '%s\n' "$(expand_tilde "$dest")"
  done < "$TSV"
}

check_disjoint() {
  local dup a b
  dup="$(all_dests | sort | uniq -d)"
  [ -z "$dup" ] || die "harnesses.tsv: duplicate dest: $dup"
  while IFS= read -r a; do
    while IFS= read -r b; do
      [ "$a" = "$b" ] && continue
      case "$(fold "$a/")" in "$(fold "$b")"/*) die "harnesses.tsv: dest '$a' lies inside dest '$b'" ;; esac
    done <<EOF_B
$(all_dests)
EOF_B
  done <<EOF_A
$(all_dests)
EOF_A
}

report_skips() {  # harness-detection report: names every found AND skipped detect dir
  local content detect dest
  while IFS=$'\t' read -r content detect dest; do
    case "$content" in ''|'#'*) continue ;; esac
    [ "$detect" = "-" ] && continue
    if [ -d "$(expand_tilde "$detect")" ]; then
      note "found: $(expand_tilde "$detect") ($content will be installed)"
    else
      note "skipped: $(expand_tilde "$detect") not found (no $content for that harness)"
    fi
  done < "$TSV"
}

active_rows() {  # stdout: content<TAB>expanded_dest — data only, no notes
  local content detect dest
  while IFS=$'\t' read -r content detect dest; do
    case "$content" in ''|'#'*) continue ;; esac
    dest="${dest%$'\r'}"   # belt-and-braces vs CRLF checkouts
    if [ "$detect" = "-" ] || [ -d "$(expand_tilde "$detect")" ]; then
      printf '%s\t%s\n' "$content" "$(expand_tilde "$dest")"
    fi
  done < "$TSV"
}

units() {  # $1 = content type; stdout: name<TAB>absolute_source
  local d f
  case "$1" in
    skills)
      for d in "$REPO_DIR"/skills/*/; do
        [ -d "$d" ] || continue
        d="${d%/}"
        printf '%s\t%s\n' "$(basename "$d")" "$d"
      done ;;
    agents|commands)
      for f in "$REPO_DIR/$1"/*.md; do
        [ -f "$f" ] || continue
        printf '%s\t%s\n' "$(basename "$f")" "$f"
      done ;;
    *) die "harnesses.tsv: unknown content type '$1'" ;;
  esac
}

planned() {  # stdout: src<TAB>dest for every active row x unit
  active_rows | while IFS=$'\t' read -r content dest_dir; do
    units "$content" | while IFS=$'\t' read -r name src; do
      printf '%s\t%s\n' "$src" "$dest_dir/$name"
    done
  done
}

ensure_dir() {  # create $1, recording each newly created level in the receipt
  local d="$1"
  [ -d "$d" ] && return 0
  ensure_dir "$(dirname "$d")"
  note "mkdir: $d"
  if [ "$DRY" = 0 ]; then
    receipt_append dir - "$d"   # append-before-act: a crash never strands an unrecorded dir
    [ -d "$d" ] || mkdir "$d"   # receipt bootstrap may have just created this very dir
  fi
}

receipt_append() {  # mode src dest
  [ "$DRY" = 1 ] && return 0
  if [ ! -f "$RECEIPT" ]; then
    mkdir -p "$RECEIPT_DIR"   # unrecorded by design; uninstall prunes it explicitly
    printf '%s\n' "$RECEIPT_HEADER" > "$RECEIPT"
  fi
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$RECEIPT"
}

remove_path() {  # link-aware delete: a link is removed as an object, never traversed
  local p="$1"
  if [ -L "$p" ]; then rm "$p"
  elif [ -d "$p" ]; then rm -rf "$p"
  elif [ -e "$p" ]; then rm -f "$p"
  fi
}

receipt_current() {  # deduped receipt: last line per (folded) dest wins
  [ -f "$RECEIPT" ] || return 0
  awk -F'\t' -v fold="$CASE_FOLD" '
    /^#/ { next } NF < 3 { next }
    {
      key = $3; if (fold) key = tolower(key)
      line[key] = $0
      if (!(key in seen)) { order[++n] = key; seen[key] = 1 }
    }
    END { for (i = 1; i <= n; i++) print line[order[i]] }
  ' "$RECEIPT"
}

remove_owned() {  # mode src dest — dest is receipt-listed; verify link entries before deleting
  local mode="$1" src="$2" dest="$3" target
  if [ "$mode" = link ]; then
    # A link entry may only ever delete a symlink still pointing at our
    # source. If the user replaced our link with a real file/dir (or
    # repointed it), it is theirs now — leave it.
    if [ ! -L "$dest" ]; then
      if [ -e "$dest" ]; then
        note "warning: $dest is no longer our symlink — leaving it"
        STATUS=2
      fi
      return 0
    fi
    target="$(readlink "$dest")"
    if [ "$(fold "$target")" != "$(fold "$src")" ]; then
      note "warning: $dest points at '$target', not our '$src' — leaving it"
      STATUS=2
      return 0
    fi
  fi
  remove_path "$dest"
}

is_ours() {  # 0 iff receipt lists $1 (folded compare); avoids grep -q under pipefail
  [ -f "$RECEIPT" ] || return 1
  local found=1 mode src dest
  while IFS=$'\t' read -r mode src dest; do
    [ -n "$dest" ] || continue
    [ "$(fold "$dest")" = "$(fold "$1")" ] && found=0
  done <<EOF_OURS
$(receipt_current)
EOF_OURS
  return "$found"
}

compact_receipt_and_prune() {
  [ -f "$RECEIPT" ] || return 0
  local planned_f tmp mode src dest
  planned_f="$(mktemp)"
  planned | cut -f2 | while IFS= read -r dest; do fold "$dest"; done > "$planned_f"
  tmp="$RECEIPT.tmp.$$"
  printf '%s\n' "$RECEIPT_HEADER" > "$tmp"
  while IFS=$'\t' read -r mode src dest; do
    [ -n "$mode" ] || continue
    if [ "$mode" = dir ] || grep -Fxq "$(fold "$dest")" "$planned_f"; then
      printf '%s\t%s\t%s\n' "$mode" "$src" "$dest" >> "$tmp"
    else
      note "remove stale: $dest"
      if [ "$DRY" = 1 ]; then
        printf '%s\t%s\t%s\n' "$mode" "$src" "$dest" >> "$tmp"
      else
        remove_owned "$mode" "$src" "$dest"
      fi
    fi
  done <<EOF_RCPT
$(receipt_current)
EOF_RCPT
  if [ "$DRY" = 1 ]; then rm -f "$tmp"; else mv "$tmp" "$RECEIPT"; fi
  rm -f "$planned_f"
}

install_unit() {  # src dest
  local src="$1" dest="$2"
  ensure_dir "$(dirname "$dest")"
  note "install ($MODE): $src -> $dest"
  [ "$DRY" = 1 ] && return 0
  receipt_append "$MODE" "$src" "$dest"   # before install: crash never strands an owned dest
  remove_path "$dest"
  if [ "$MODE" = link ]; then
    ln -s "$src" "$dest"
    [ -L "$dest" ] || die "symlink not created at $dest — in Git Bash set MSYS=winsymlinks:nativestrict, or use install.ps1 -Link"
  else
    if [ -d "$src" ]; then cp -R "$src" "$dest"; else cp "$src" "$dest"; fi
  fi
}

do_install() {
  compact_receipt_and_prune
  local src dest
  while IFS=$'\t' read -r src dest; do
    if { [ -e "$dest" ] || [ -L "$dest" ]; } && [ "$FORCE" = 0 ] && ! is_ours "$dest"; then
      note "skip (exists, not ours — rerun with --force to claim): $dest"
      STATUS=2
      continue
    fi
    install_unit "$src" "$dest"
  done <<EOF_PLAN
$(planned)
EOF_PLAN
}

do_uninstall() {
  if [ ! -f "$RECEIPT" ]; then
    note "nothing to uninstall (no receipt at $RECEIPT)"
    return 0
  fi
  local entries mode src dest
  entries="$(receipt_current)"   # capture BEFORE deleting the receipt
  while IFS=$'\t' read -r mode src dest; do
    [ -n "$mode" ] && [ "$mode" != dir ] || continue
    note "remove: $dest"
    if [ "$DRY" = 0 ]; then
      if [ "$FORCE" = 1 ]; then remove_path "$dest"; else remove_owned "$mode" "$src" "$dest"; fi
    fi
  done <<EOF_UNITS
$entries
EOF_UNITS
  note "remove: $RECEIPT"
  [ "$DRY" = 1 ] || rm -f "$RECEIPT"
  while IFS=$'\t' read -r mode src dest; do
    [ "$mode" = dir ] || continue
    note "rmdir (if empty): $dest"
    [ "$DRY" = 1 ] || rmdir "$dest" 2>/dev/null || true
  done <<EOF_DIRS
$(printf '%s\n' "$entries" | awk -F'\t' '$1=="dir" { print length($3) "\t" $0 }' | sort -rn | cut -f2-)
EOF_DIRS
  [ "$DRY" = 1 ] || rmdir "$RECEIPT_DIR" 2>/dev/null || true
}

main() {
  [ -f "$TSV" ] || die "missing $TSV"
  check_disjoint
  if [ "$ACTION" = install ]; then
    report_skips
    do_install
  else
    do_uninstall
  fi
  [ "$STATUS" = 2 ] && note "completed with skips (rerun with --force to claim them)"
  exit "$STATUS"
}

main
