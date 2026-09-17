#!/usr/bin/env bash
# Manual end-to-end demonstration of the scoped workspace lifecycle against the
# REAL Treehouse binary and real git.  Only the forge (gh) and tmux are stubbed.
# Usage: real-treehouse-lifecycle-demo.sh <firstmate-checkout>
set -u
ROOT=$1
D=$(mktemp -d "${TMPDIR:-/tmp}/fm-lifecycle-demo.XXXXXX")
D=$(cd "$D" && pwd -P)
trap 'rm -rf "$D"' EXIT
export GIT_AUTHOR_NAME=demo GIT_AUTHOR_EMAIL=demo@example.invalid
export GIT_COMMITTER_NAME=demo GIT_COMMITTER_EMAIL=demo@example.invalid
export FM_WORKSPACE_ROOT_BASE="$D/task-workspaces"
say() { printf '\n### %s\n' "$*"; }
run() { printf '$ %s\n' "$*" | sed "s|$D|<tmp>|g;s|$ROOT|<fm>|g"; "$@" 2>&1 | sed "s|$D|<tmp>|g;s|$ROOT|<fm>|g"; printf '[exit %s]\n' "${PIPESTATUS[0]}"; }

global_before=$(find "$HOME/.treehouse" -mindepth 2 -maxdepth 2 2>/dev/null | sort | shasum | cut -d' ' -f1)

# --- fixture: one origin, one shared project clone, two Firstmate homes -------
git init -q --bare "$D/origin.git"; git -C "$D/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$D/origin.git" "$D/project" 2>/dev/null
git -C "$D/project" commit -q --allow-empty -m base
git -C "$D/project" push -q origin main; git -C "$D/project" remote set-head origin main
mkdir -p "$D/home-a/state" "$D/home-b/state" "$D/fakebin"
cat > "$D/fakebin/gh" <<'SH'
#!/usr/bin/env bash
# gh pr view <url> ... : one recorded forge row per PR number
row="$(dirname "$0")/pr-${3##*/}.tsv"; [ -f "$row" ] && cat "$row"
SH
cat > "$D/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in display-message) printf '@pane\n' ;; new-window) printf '@9\n' ;; esac; exit 0
SH
chmod +x "$D/fakebin/gh" "$D/fakebin/tmux"
export PATH="$D/fakebin:$PATH" TMUX=''

# shellcheck disable=SC1091
. "$ROOT/bin/fm-wake-lib.sh"; . "$ROOT/bin/fm-workspace-lib.sh"

say "1. Two homes sharing one project resolve distinct, non-global Treehouse roots"
ROOT_A=$(fm_workspace_root_for_home "$D/home-a"); ROOT_B=$(fm_workspace_root_for_home "$D/home-b")
printf 'home-a root: %s\nhome-b root: %s\n' "$ROOT_A" "$ROOT_B" | sed "s|$D|<tmp>|g"
[ "$ROOT_A" != "$ROOT_B" ] && echo "distinct: yes"

spawn_like() {  # <home> <root> <task-id> <branch> <start-point> <pr-number> <base-branch>
  local home=$1 root=$2 id=$3 branch=$4 start=$5 n=$6 base=$7 holder wt head
  fm_workspace_prepare_root "$root"
  holder=$(fm_workspace_lease_holder "$id" "$home")
  wt=$(cd "$D/project" && treehouse --root "$root" get --lease --lease-holder "$holder" 2>/dev/null)
  fm_treehouse_slot_owner_claim "$wt" "$id" "$home"
  git -C "$wt" checkout -q -b "$branch" "$start"
  printf '%s\n' "$id" > "$wt/$id.txt"; printf '.env\n' > "$wt/.gitignore.$id"
  [ -f "$wt/.gitignore" ] || printf '.env\n' > "$wt/.gitignore"
  git -C "$wt" add -A; git -C "$wt" commit -q -m "work for $id"
  head=$(git -C "$wt" rev-parse HEAD)
  git -C "$wt" push -q origin "HEAD:refs/heads/$branch" "HEAD:refs/pull/$n/head"
  printf '%s\t%s\t%s\t%s\t%s\n' OPEN "$head" "$branch" "$base" "https://github.com/example/repo/pull/$n" > "$D/fakebin/pr-$n.tsv"
  {
    printf 'window=firstmate:fm-%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\n' "$id" "$id" "$wt" "$D/project"
    printf 'harness=codex\nkind=ship\nmode=no-mistakes\nyolo=off\nspawn_gen=demo\n'
    printf 'workspace_state=active\nworkspace_root=%s\nworkspace_lease_holder=%s\n' "$root" "$holder"
    printf 'pr=https://github.com/example/repo/pull/%s\npr_head=%s\n' "$n" "$head"
  } > "$home/state/$id.meta"; chmod 0600 "$home/state/$id.meta"
  printf '%s\n' "$wt"
}

say "2. Allocate a stacked pair in home-a (PR 7 -> main, PR 8 -> fm/lower) and one task in home-b (PR 9)"
WT_LOWER=$(spawn_like "$D/home-a" "$ROOT_A" lower fm/lower main 7 main)
WT_UPPER=$(spawn_like "$D/home-a" "$ROOT_A" upper fm/upper fm/lower 8 fm/lower)
WT_B=$(spawn_like "$D/home-b" "$ROOT_B" btask fm/btask main 9 main)
UPPER_HEAD=$(git -C "$WT_UPPER" rev-parse HEAD)
printf 'lower: %s\nupper: %s\nbtask: %s\n' "$WT_LOWER" "$WT_UPPER" "$WT_B" | sed "s|$D|<tmp>|g"
(cd "$D/project" && run treehouse --root "$ROOT_A" status)
(cd "$D/project" && run treehouse --root "$ROOT_B" status)

say "3. Refusals preserve non-reconstructable work (home-a upper task)"
echo scratch > "$WT_UPPER/untracked-notes.txt"
FM_HOME="$D/home-a" run "$ROOT/bin/fm-workspace.sh" release upper
rm "$WT_UPPER/untracked-notes.txt"
echo 'TOKEN=x' > "$WT_UPPER/.env"
FM_HOME="$D/home-a" run "$ROOT/bin/fm-workspace.sh" release upper
rm "$WT_UPPER/.env"
git -C "$WT_UPPER" commit -q --allow-empty -m "unpushed local commit"
FM_HOME="$D/home-a" run "$ROOT/bin/fm-workspace.sh" release upper
git -C "$WT_UPPER" reset -q --hard "$UPPER_HEAD"
echo "after refusals the workspace still exists: $([ -d "$WT_UPPER" ] && echo yes) state=$(sed -n 's/^workspace_state=//p' "$D/home-a/state/upper.meta")"

say "4. Clean, fully pushed stacked PR releases; real Treehouse returns and destroys the slot"
FM_HOME="$D/home-a" run "$ROOT/bin/fm-workspace.sh" release upper
FM_HOME="$D/home-a" run "$ROOT/bin/fm-workspace.sh" release lower
echo "idempotent retry:"
FM_HOME="$D/home-a" run "$ROOT/bin/fm-workspace.sh" release upper
(cd "$D/project" && run treehouse --root "$ROOT_A" status)
echo "upper worktree dir exists: $([ -d "$WT_UPPER" ] && echo yes || echo no); lower: $([ -d "$WT_LOWER" ] && echo yes || echo no)"
echo "--- home-a/state/upper.meta (durable reconstruction record) ---"
sed "s|$D|<tmp>|g" "$D/home-a/state/upper.meta"

say "5. home-b's workspace in the same project was never touched by home-a's cleanup"
(cd "$D/project" && run treehouse --root "$ROOT_B" status)
echo "btask worktree intact: $([ -d "$WT_B" ] && git -C "$WT_B" rev-parse --abbrev-ref HEAD)"

say "6. Restore reconstructs the exact stacked branch and head from the remote"
FM_HOME="$D/home-a" run "$ROOT/bin/fm-workspace.sh" restore upper
NEW_WT=$(sed -n 's/^worktree=//p' "$D/home-a/state/upper.meta")
echo "branch=$(git -C "$NEW_WT" rev-parse --abbrev-ref HEAD) head=$(git -C "$NEW_WT" rev-parse HEAD) expected=$UPPER_HEAD"
echo "state=$(sed -n 's/^workspace_state=//p' "$D/home-a/state/upper.meta") base=$(sed -n 's/^workspace_base=//p' "$D/home-a/state/upper.meta")"
echo "unique layer vs its stacked base:"; git -C "$NEW_WT" log --oneline origin/fm/lower..HEAD
echo "restored-but-never-relaunched workspace releases again:"
FM_HOME="$D/home-a" run "$ROOT/bin/fm-workspace.sh" release upper
(cd "$D/project" && run treehouse --root "$ROOT_A" status)

say "7. Legacy pool audit (dry-run) and conservative reclaim against a legacy-style root"
LEG="$D/legacy-home"; mkdir -p "$LEG"
L1=$(cd "$D/project" && treehouse --root "$LEG" get --lease 2>/dev/null)
L2=$(cd "$D/project" && treehouse --root "$LEG" get --lease 2>/dev/null)
echo 'unique unpushed work' > "$L2/unique.txt"
(cd "$D/project" && treehouse --root "$LEG" return --force "$L1" >/dev/null 2>&1)
(cd "$D/project" && run "$ROOT/bin/fm-workspace.sh" audit-legacy "$LEG")
echo "after audit both legacy slots still exist: $([ -d "$L1" ] && echo L1) $([ -d "$L2" ] && echo L2)"
(cd "$D/project" && run "$ROOT/bin/fm-workspace.sh" reclaim-legacy "$LEG")
echo "after reclaim: idle clean slot L1 exists=$([ -d "$L1" ] && echo yes || echo no); leased slot L2 with unique work exists=$([ -d "$L2" ] && echo yes || echo no) unique.txt=$(cat "$L2/unique.txt" 2>/dev/null)"

say "8. The user-global ~/.treehouse pool listing is byte-identical before and after"
global_after=$(find "$HOME/.treehouse" -mindepth 2 -maxdepth 2 2>/dev/null | sort | shasum | cut -d' ' -f1)
echo "before=$global_before after=$global_after unchanged=$([ "$global_before" = "$global_after" ] && echo yes || echo NO)"
