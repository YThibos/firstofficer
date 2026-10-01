#!/usr/bin/env bash
# Disposable end-to-end drive of bin/fm-upstream-sync.sh against local bare
# remotes (upstream, origin) with stubbed no-mistakes gate and gh forge.
set -u
SCRIPT=$1
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-sync-e2e.XXXXXX")
trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=e2e GIT_AUTHOR_EMAIL=e2e@example.invalid GIT_COMMITTER_NAME=e2e GIT_COMMITTER_EMAIL=e2e@example.invalid
g() { git -C "$@"; }
say() { printf '\n$ %s\n' "$*"; }
git init -q --bare -b main "$T/upstream.git"; git init -q --bare -b main "$T/origin.git"
git init -q -b main "$T/up"; mkdir -p "$T/up/bin"
printf 'upstream v1\n' > "$T/up/README"; printf 'rules v1\n' > "$T/up/AGENTS.md"
cat > "$T/up/bin/fm-lint.sh" <<'S'
#!/usr/bin/env bash
echo "[stub fm-lint.sh ran in $PWD]"
S
cat > "$T/up/bin/fm-test-run.sh" <<'S'
#!/usr/bin/env bash
echo "FULL LOCAL SUITE RAN $*" >> "$E2E_TMP/full-suite-ran"
S
chmod +x "$T/up/bin/"*.sh
g "$T/up" add -A; g "$T/up" commit -qm 'upstream base'; g "$T/up" push -q "$T/upstream.git" main
git clone -q "$T/upstream.git" "$T/fork"; g "$T/fork" remote rename origin upstream
g "$T/fork" remote add origin "https://github.com/acme/fork.git"
g "$T/fork" config remote.origin.pushurl "$T/origin.git"
g "$T/fork" config remote.origin.url "$T/origin.git"
printf 'fork note\n' > "$T/fork/FORK"; g "$T/fork" add -A; g "$T/fork" commit -qm 'fork divergence'
g "$T/fork" push -q origin main; g "$T/fork" fetch -q origin; g "$T/fork" remote set-head origin main >/dev/null
for i in 1 2; do printf 'upstream change %s\n' $i >> "$T/up/README"; g "$T/up" commit -qam "upstream change $i"; done
g "$T/up" push -q "$T/upstream.git" main
export E2E_TMP=$T
mkdir "$T/fakebin"
cat > "$T/fakebin/no-mistakes" <<S
#!/usr/bin/env bash
echo "[stub no-mistakes] cwd=\$PWD args=\$*" | tee -a '$T/nm.log'
b=\$(git symbolic-ref --short HEAD); git push -q origin "\$b:refs/heads/\$b"
echo https://github.com/acme/fork/pull/42 > '$T/open-pr'; echo "outcome: pr opened"
S
cat > "$T/fakebin/gh" <<S
#!/usr/bin/env bash
echo "[stub gh] \$*" >> '$T/gh.log'
[ "\$1 \$2" = "pr list" ] && cat '$T/open-pr' 2>/dev/null; true
S
chmod +x "$T/fakebin/"*
export PATH="$T/fakebin:$PATH" FM_ROOT_OVERRIDE="$T/fork"
origin_main() { git --git-dir="$T/origin.git" rev-parse --short main; }
echo "origin/main before: $(origin_main)"
say fm-upstream-sync.sh preflight; "$SCRIPT" preflight; echo "rc=$?"
say fm-upstream-sync.sh merge; "$SCRIPT" merge; echo "rc=$?"
BR=$(g "$T/fork-upstream-sync" symbolic-ref --short HEAD); HEAD_SHA=$(g "$T/fork-upstream-sync" rev-parse HEAD)
say fm-upstream-sync.sh land; "$SCRIPT" land; echo "rc=$?"
echo "--- checks after standard land ---"
echo "origin/main after land: $(origin_main) (unchanged = nothing fast-forwarded)"
echo "origin/$BR: $(git --git-dir="$T/origin.git" rev-parse "$BR") vs local sync HEAD $HEAD_SHA"
echo "origin/$BR parents (merge commit kept, not rebased/squashed): $(git --git-dir="$T/origin.git" log -1 --format=%P "$BR" | wc -w)"
echo "full local suite invoked: $([ -e "$T/full-suite-ran" ] && cat "$T/full-suite-ran" || echo no)"
echo "no-mistakes invocations: $(wc -l < "$T/nm.log")"
say fm-upstream-sync.sh land  '# rerun after finished run'; "$SCRIPT" land; echo "rc=$?"
echo "no-mistakes invocations after rerun: $(wc -l < "$T/nm.log") (no new pipeline)"
echo "--- adversarial: another PR lands on origin/main before the sync PR merges ---"
git clone -q "$T/origin.git" "$T/other"; echo x > "$T/other/OTHER"; g "$T/other" add -A; g "$T/other" commit -qm 'other fork PR'; g "$T/other" push -q origin main
cp "$T/nm.log" "$T/nm.before"
printf 'fix\n' > "$T/fork-upstream-sync/FIX"; g "$T/fork-upstream-sync" add -A; g "$T/fork-upstream-sync" commit -qm 'ci fix'
say fm-upstream-sync.sh land '# origin/main moved'; "$SCRIPT" land; echo "rc=$?"
cmp -s "$T/nm.log" "$T/nm.before" && echo "pipeline not started on refusal: yes"
say git merge origin/main '(as instructed, never rebase)'; g "$T/fork-upstream-sync" fetch -q origin; g "$T/fork-upstream-sync" merge -q --no-edit origin/main
say fm-upstream-sync.sh land; "$SCRIPT" land; echo "rc=$?"
echo "origin/main still: $(origin_main)"
echo "--- owner merges the PR with a merge commit on origin ---"
g "$T/other" fetch -q origin; g "$T/other" merge -q --no-ff --no-edit "origin/$BR"; g "$T/other" push -q origin main
echo "upstream moves on again"; echo more >> "$T/up/README"; g "$T/up" commit -qam 'upstream later'; g "$T/up" push -q "$T/upstream.git" main
g "$T/fork" fetch -q upstream
say fm-upstream-sync.sh land '# cleanup after merge'; "$SCRIPT" land; echo "rc=$?"
echo "sync copy exists afterwards: $([ -e "$T/fork-upstream-sync" ] && echo yes || echo no)"
echo "upstream.git ever pushed by fork? upstream main = $(git --git-dir="$T/upstream.git" log -1 --format=%s main)"
say fm-upstream-sync.sh --help; "$SCRIPT" --help 2>&1 | sed -n 1,25p
