#!/usr/bin/env bash
# Live reproduction of the reported sidebar defect: projected children of a
# custom-named parent ("ships-ahoy") must sit directly under THAT parent, not
# after another custom-named parent's ("green") children.
#
# Usage: green-ships-repro.sh <firstmate-root-under-test> <run-label>
# Drives the real bin/fm-spawn.sh of <root> against an isolated, generated
# fm-lab-* Herdr session. Every Herdr call goes through bin/fm-herdr-lab.sh
# (name/provision/run/teardown); production spawns reach Herdr only through a
# PATH shim that forwards to the helper's guarded `run`.
set -u
CODE_ROOT=$1
RUN=$2
WT=$HOME/.no-mistakes/worktrees/30431f189f2f/01M654F4X5YKE75KQD8JWQ1SK4
HERDR_LAB_HELPER="$WT/bin/fm-herdr-lab.sh"
# shellcheck source=/dev/null
. "$WT/tests/herdr-test-safety.sh"   # FM_GATE_REFUSE_BYPASS=1, as the real E2E does
herdr_forget_inherited_pane

FAILS=0
check() { if eval "$2"; then echo "ok - $1"; else echo "not ok - $1"; FAILS=$((FAILS + 1)); fi; }

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-green-ships.XXXXXX")
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name ws-parent-grp) || { echo "not ok - lab name"; exit 1; }
export HERDR_SESSION="$HERDR_LAB_SESSION"
echo "code root: $CODE_ROOT ($RUN)"
echo "lab session: $HERDR_LAB_SESSION"
WORKTREES=()
CLEANED=0
cleanup_all() {
  local wt status=0
  [ "$CLEANED" = 0 ] || return 0
  CLEANED=1
  for wt in ${WORKTREES[@]+"${WORKTREES[@]}"}; do
    [ -n "$wt" ] && treehouse return --force "$wt" >/dev/null 2>&1
  done
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=$?
  find "$TMP_ROOT" -type d -exec chmod u+rwx {} + 2>/dev/null
  rm -rf "$TMP_ROOT"
  [ "$status" = 0 ] && echo "ok - lab session torn down; default fleet session tripwire unchanged" \
    || echo "not ok - lab teardown or default-session tripwire failed ($status)"
  return "$status"
}
trap cleanup_all EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || { echo "not ok - provision"; exit 1; }
lab() { "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
LAB_SOCKET=$(lab session list --json 2>/dev/null \
  | jq -r --arg s "$HERDR_LAB_SESSION" '.sessions[]? | select(.name == $s) | .socket_path')
[ -n "$LAB_SOCKET" ] || { echo "not ok - lab socket"; exit 1; }

FAKEBIN="$TMP_ROOT/fakebin"; mkdir -p "$FAKEBIN"
{
  printf '#!/usr/bin/env bash\nset -u\n'
  printf 'LAB_SESSION=%q LAB_HELPER=%q ORIGINAL_PATH=%q\n' "$HERDR_LAB_SESSION" "$HERDR_LAB_HELPER" "$PATH"
  cat <<'SH'
args=("$@")
last=$((${#args[@]} - 1))
if [ "$last" -ge 1 ] && [ "${args[$((last - 1))]}" = --session ] && [ "${args[$last]}" = "$LAB_SESSION" ]; then
  unset "args[$last]" "args[$((last - 1))]"
fi
set -- ${args[@]+"${args[@]}"}
for arg in "$@"; do
  case "$arg" in --session|--session=*) echo "lab herdr shim: refusing $arg" >&2; exit 1 ;; esac
done
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$LAB_SESSION" "$@"
SH
} > "$FAKEBIN/herdr"
chmod +x "$FAKEBIN/herdr"

make_workspace() {  # <label> -> "<ws> <tab> <pane>"
  lab workspace create --cwd "$TMP_ROOT" --label "$1" --no-focus 2>/dev/null \
    | jq -r '[.result.workspace.workspace_id, .result.tab.tab_id, .result.root_pane.pane_id] | @tsv' | tr '\t' ' '
}
ws_ids() { lab workspace list 2>/dev/null | jq -c '[.result.workspaces[].workspace_id]'; }
show_sidebar() {  # <title>
  echo "--- sidebar order: $1 ---"
  lab workspace list 2>/dev/null | jq -r '.result.workspaces | to_entries[]
    | "  \(.key): \(.value.label)\(if .value.focused then "   [selected]" else "" end)"'
}
journal_field() { grep "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2-; }
pane_ws() { lab pane get "$1" 2>/dev/null | jq -r '.result.pane.workspace_id // empty'; }

PROJ="$TMP_ROOT/scratch-project"
mkdir -p "$PROJ"; git -C "$PROJ" init -q; printf '# scratch\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name=t -c user.email=t@example.invalid commit -qm initial
git clone --quiet --bare "$PROJ" "$PROJ.origin.git"; git -C "$PROJ" remote add origin "file://$PROJ.origin.git"

for home in green ships; do
  mkdir -p "$TMP_ROOT/$home-home/state" "$TMP_ROOT/$home-home/config"
  : > "$TMP_ROOT/$home-home/config/herdr-presentation-spaces"   # presentation spaces ON
done
GREEN_HOME="$TMP_ROOT/green-home"; SHIPS_HOME="$TMP_ROOT/ships-home"
write_brief() {  # <home> <id>  (same brief shape the launcher E2E uses)
  mkdir -p "$1/data/$2"
  printf "# Task\n## Captain's intent\nReproduce sidebar grouping for %s.\n\n## Firstmate spec\nVerify the worker is placed under its parent.\n" "$2" > "$1/data/$2/brief.md"
}
for id in green1 green2 green3; do write_brief "$GREEN_HOME" "$id"; done
for id in ships1 ships2 ships3; do write_brief "$SHIPS_HOME" "$id"; done

read -r WS_OTHER WS_OTHER_TAB _ <<<"$(make_workspace captain-other)"
read -r WS_GREEN _ PANE_GREEN <<<"$(make_workspace green)"
read -r WS_SHIPS _ PANE_SHIPS <<<"$(make_workspace ships-ahoy)"
read -r WS_DECOY _ _ <<<"$(make_workspace green)"   # duplicated label; never the launcher
lab tab focus "$WS_OTHER_TAB" >/dev/null 2>&1
DECOY_TABS_BEFORE=$(lab tab list --workspace "$WS_DECOY" 2>/dev/null | jq -c '[.result.tabs[].tab_id]')
show_sidebar "before any spawn"

spawn() {  # <launcher-pane> <home> <id>
  env PATH="$FAKEBIN:$PATH" HERDR_ENV=1 HERDR_PANE_ID="$1" HERDR_SESSION="$HERDR_LAB_SESSION" \
    HERDR_SOCKET_PATH="$LAB_SOCKET" FM_SPAWN_NO_GUARD=1 FM_HOME="$2" FM_ROOT_OVERRIDE="$CODE_ROOT" \
    "$CODE_ROOT/bin/fm-spawn.sh" "$3" "$PROJ" "sh -c 'echo repro-ok'" --backend herdr --mode no-mistakes --yolo off \
    >"$TMP_ROOT/$3.out" 2>"$TMP_ROOT/$3.err"
  echo $? > "$TMP_ROOT/$3.rc"
}
after_spawn() {  # <home> <id>
  local wt
  wt=$(grep '^worktree=' "$1/state/$2.meta" 2>/dev/null | cut -d= -f2-)
  [ -n "$wt" ] && WORKTREES+=("$wt")
  echo "spawn $2 rc=$(cat "$TMP_ROOT/$2.rc")"
  grep -i -E 'warning|refus|ambiguous' "$TMP_ROOT/$2.err" | sed 's/^/  stderr: /' | head -5
  [ "$(cat "$TMP_ROOT/$2.rc")" = 0 ] || tail -8 "$TMP_ROOT/$2.err" | sed 's/^/  stderr-tail: /'
}
child_ws() { pane_ws "$(grep '^herdr_pane_id=' "$1/state/$2.meta" 2>/dev/null | cut -d= -f2-)"; }
offset() {  # <parent-ws> <child-ws> -> child index minus parent index
  lab workspace list 2>/dev/null | jq -r --arg p "$1" --arg c "$2" \
    '.result.workspaces | map(.workspace_id) | if index($c) == null then "absent" else (index($c) - index($p)) end'
}

# Step 1: green already has a child block (the screenshot's green children).
spawn "$PANE_GREEN" "$GREEN_HOME" green1; after_spawn "$GREEN_HOME" green1
show_sidebar "after green1"
# Step 2: ships-ahoy launches its first child (the reported misplacement).
spawn "$PANE_SHIPS" "$SHIPS_HOME" ships1; after_spawn "$SHIPS_HOME" ships1
show_sidebar "after ships1"
# Step 3: concurrent launches from both parents under the session-wide lock.
spawn "$PANE_GREEN" "$GREEN_HOME" green2 & p1=$!
spawn "$PANE_SHIPS" "$SHIPS_HOME" ships2 & p2=$!
wait "$p1" "$p2"
after_spawn "$GREEN_HOME" green2; after_spawn "$SHIPS_HOME" ships2
show_sidebar "after concurrent green2 + ships2"
# Step 4: one more interleaved pair, ships first this time.
spawn "$PANE_SHIPS" "$SHIPS_HOME" ships3; after_spawn "$SHIPS_HOME" ships3
spawn "$PANE_GREEN" "$GREEN_HOME" green3; after_spawn "$GREEN_HOME" green3
show_sidebar "final"

echo "--- assertions ---"
for id in green1 green2 green3 ships1 ships2 ships3; do
  case "$id" in green*) home=$GREEN_HOME parent=$WS_GREEN plabel=green ;; *) home=$SHIPS_HOME parent=$WS_SHIPS plabel=ships-ahoy ;; esac
  j="$home/state/$id.herdr-presentation"
  echo "journal $id: version=$(journal_field "$j" version) parent_workspace_id=$(journal_field "$j" parent_workspace_id) parent_label=$(journal_field "$j" parent_label)"
  check "$id spawned successfully" '[ "$(cat "$TMP_ROOT/$id.rc")" = 0 ]'
  check "$id published an exact v2 binding to its own parent ($plabel) and live label" \
    '[ "$(journal_field "$j" version)" = 2 ] && [ "$(journal_field "$j" parent_workspace_id)" = "$parent" ] && [ "$(journal_field "$j" parent_label)" = "$plabel" ]'
done
FINAL=$(lab workspace list 2>/dev/null | jq -c '.result.workspaces | map(.workspace_id)')
G_BLOCK=$(for id in green1 green2 green3; do child_ws "$GREEN_HOME" "$id"; done | jq -R . | jq -sc .)
S_BLOCK=$(for id in ships1 ships2 ships3; do child_ws "$SHIPS_HOME" "$id"; done | jq -R . | jq -sc .)
check "green's three children form one contiguous block immediately under green" \
  '[ "$(jq -n --argjson f "$FINAL" --argjson b "$G_BLOCK" --arg p "$WS_GREEN" "(\$f | index(\$p)) as \$i | (\$f[\$i+1:\$i+4] | sort) == (\$b | sort)")" = true ]'
check "ships-ahoy's three children form one contiguous block immediately under ships-ahoy" \
  '[ "$(jq -n --argjson f "$FINAL" --argjson b "$S_BLOCK" --arg p "$WS_SHIPS" "(\$f | index(\$p)) as \$i | (\$f[\$i+1:\$i+4] | sort) == (\$b | sort)")" = true ]'
check "no ships-ahoy child sits between green and ships-ahoy" \
  '[ "$(jq -n --argjson f "$FINAL" --argjson b "$S_BLOCK" --arg g "$WS_GREEN" --arg s "$WS_SHIPS" "[\$b[] as \$c | (\$f | index(\$c)) as \$x | select(\$x > (\$f | index(\$g)) and \$x < (\$f | index(\$s)))] | length == 0")" = true ]'
check "the duplicate-labeled 'green' decoy workspace gained no tabs and kept its label" \
  '[ "$(lab tab list --workspace "$WS_DECOY" 2>/dev/null | jq -c "[.result.tabs[].tab_id]")" = "$DECOY_TABS_BEFORE" ] && [ "$(lab workspace list | jq -r --arg d "$WS_DECOY" ".result.workspaces[] | select(.workspace_id == \$d) | .label")" = green ]'
check "the captain's selected workspace never changed" \
  '[ "$(lab workspace list | jq -r "[.result.workspaces[] | select(.focused) | .workspace_id][0]")" = "$WS_OTHER" ]'
echo "result: $FAILS failing assertion(s)"
cleanup_all; rc=$?
trap - EXIT
[ "$FAILS" = 0 ] && [ "$rc" = 0 ]
