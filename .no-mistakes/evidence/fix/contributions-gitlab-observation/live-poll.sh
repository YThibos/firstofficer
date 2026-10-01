#!/usr/bin/env bash
# Live, read-only poll of real forges from a disposable lab FM_HOME.
# Usage: live-poll.sh <label> <polls> <url>...
set -u
ROOT=${ROOT:-/home/thibyann001/.no-mistakes/worktrees/04c39aeaee8f/01M3W9Z86YBRJ844HT5H37VJ9E}
label=$1 polls=$2; shift 2
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux" "$LAB/shim"
cat > "$LAB/shim/glab" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$LAB/glab-calls"
exec /home/thibyann001/.local/bin/glab "\$@"
EOF
chmod +x "$LAB/shim/glab"
printf '# Backlog\n\n## Queued\n' > "$LAB/data/backlog.md"
i=0; for url in "$@"; do i=$((i+1)); printf -- '- [ ] live%s - Contribution %s (repo: sample) (kind: ship)\n' "$i" "$url" >> "$LAB/data/backlog.md"; done
echo "### [$label] lab=$LAB"; echo "### backlog:"; cat "$LAB/data/backlog.md"
run() { env -u TMUX -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  TMUX_TMPDIR="$LAB/tmux" PATH="$LAB/shim:$PATH" FM_HOME="$LAB" FM_CONTRIBUTIONS_BUDGET=25 "$@"; }
for n in $(seq 1 "$polls"); do
  : > "$LAB/glab-calls"
  echo; echo "### poll $n stdout (rc follows):"
  run "$ROOT/bin/fm-contributions.sh" poll; echo "rc=$?"
  echo "### poll $n glab calls:"; cat "$LAB/glab-calls"
done
echo; echo "### persisted records (url, state, error, checked_at, head, checks):"
for f in "$LAB"/data/*/contributions.json; do jq -c '.records[] | {task:input_filename|split("/")[-2], url, kind, error, checked_at, state:.observation.state, head:.observation.head, mergeable:.observation.mergeable, review_decision:.observation.review_decision, checks:[.observation.checks[]? | {name,status,conclusion}], pending:(.pending|length), seen:(.seen|length)}' "$f" 2>/dev/null; done
echo; echo "### snapshot coverage (fm-contributions.sh snapshot via fleet input):"
run "$ROOT/bin/fm-fleet-snapshot.sh" --contribution-input > "$LAB/input.json" 2>/dev/null
run "$ROOT/bin/fm-contributions.sh" snapshot "$LAB/input.json" --all 2>&1 | jq -c '.' 2>/dev/null | head -40 || run "$ROOT/bin/fm-contributions.sh" snapshot "$LAB/input.json" --all
rm -rf "$LAB"; echo "### lab removed: $([ -e "$LAB" ] && echo no || echo yes)"
