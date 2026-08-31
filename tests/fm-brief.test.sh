#!/usr/bin/env bash
# Behavior tests for bin/fm-brief.sh.
#
# Regression coverage for the heredoc-in-command-substitution parse bug (issues
# #166, #958, #1069). Building a variable with `VAR=$(cat <<EOF ... EOF)` is
# unsafe on Bash 3.2 (macOS /bin/bash): the lexer scans for the matching `)` of
# the command substitution textually and tracks quote state through the heredoc
# body, so a single apostrophe, unbalanced quote, or unbalanced paren anywhere
# in that body breaks parsing of the *entire rest of the script* - `bash -n`
# fails, not just the generated brief. The DOD and Herdr-section builders now
# use `IFS= read -r -d '' VAR <<EOF || true` instead, which removes the `$(...)`
# wrapper and eliminates the whole defect class regardless of future prose.
# test_no_heredoc_in_command_substitution guards that structure directly.
# Ambient `bash -n` here is Bash 5 and cannot see the bug, so the real
# cross-version enforcement lives in the macos-stock-bash CI job.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief)
BRIEF_HOME="$TMP_ROOT/home"
mkdir -p "$BRIEF_HOME/data"

# The script itself must always parse under the ambient bash. That is Bash 5 in
# CI and locally, where the issue #958/#1069 parser bug does not fire, so this
# is a weak guard on its own; test_no_heredoc_in_command_substitution and the
# macos-stock-bash CI job carry the real cross-version enforcement.
test_script_parses() {
  local out rc
  out=$(bash -n "$ROOT/bin/fm-brief.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-brief.sh must parse cleanly (got: $out)"
  [ -z "$out" ] || fail "bash -n bin/fm-brief.sh emitted unexpected output: $out"
  pass "fm-brief.sh: bash -n succeeds"
}

# Structural class guard (issues #166, #958, #1069): never build a variable by
# wrapping a heredoc in a command substitution (`VAR=$(cat <<EOF ... EOF)`).
# That construct is what breaks Bash 3.2 parsing, and pinning one historical
# apostrophe phrase (as the old test did) missed the #945 reintroduction. This
# guards the *shape* directly against the whole file, so any future DOD or
# section builder that reintroduces the class fails here regardless of prose.
test_no_heredoc_in_command_substitution() {
  local unsafe safe
  unsafe="$TMP_ROOT/heredoc-in-substitution.sh"
  safe="$TMP_ROOT/plain-heredoc.sh"
  # shellcheck disable=SC2016 # Literal shell fixtures must remain unexpanded.
  printf '%s\n' 'value=$(' '  cat <<EOF' 'body' 'EOF' ')' > "$unsafe"
  # shellcheck disable=SC2016 # Literal shell fixtures must remain unexpanded.
  printf '%s\n' 'cat <<EOF' '$(' '  cat <<INNER' 'INNER' ')' 'EOF' > "$safe"
  if no_heredoc_in_command_substitution "$unsafe"; then
    fail "structural guard accepted a multiline heredoc nested in a command substitution"
  fi
  no_heredoc_in_command_substitution "$safe" \
    || fail "structural guard treated heredoc body prose as shell structure"
  no_heredoc_in_command_substitution "$ROOT/bin/fm-brief.sh" \
    || fail "fm-brief.sh wraps a heredoc in a command substitution (breaks Bash 3.2 parsing)"
  pass "fm-brief.sh: no heredoc is nested inside a command substitution (Bash 3.2 parse-safe)"
}

no_heredoc_in_command_substitution() {
  perl - "$1" <<'PERL'
use strict;
use warnings;

my $path = shift;
open my $source, '<', $path or die "$path: $!\n";
my @frames;
my @heredocs;
my $quote = '';
my $line_number = 0;

while (my $line = <$source>) {
  $line_number++;
  if (@heredocs) {
    my $candidate = $line;
    $candidate =~ s/\r?\n\z//;
    $candidate =~ s/^\t+// if $heredocs[0]{strip_tabs};
    shift @heredocs if $candidate eq $heredocs[0]{delimiter};
    next;
  }

  my $length = length $line;
  for (my $i = 0; $i < $length; $i++) {
    my $char = substr($line, $i, 1);
    if ($quote eq "'") {
      $quote = '' if $char eq "'";
      next;
    }
    if ($char eq '\\') {
      $i++;
      next;
    }
    if ($quote eq '"' && $char eq '"') {
      $quote = '';
      next;
    }
    if ($char eq "'" && $quote eq '') {
      $quote = "'";
      next;
    }
    if ($char eq '"' && $quote eq '') {
      $quote = '"';
      next;
    }
    if ($char eq '#' && $quote eq '' && ($i == 0 || substr($line, $i - 1, 1) =~ /[\s;|&()]/)) {
      last;
    }
    if ($char eq '$' && substr($line, $i + 1, 1) eq '(') {
      push @frames, { depth => 1, quote => $quote };
      $quote = '';
      $i++;
      next;
    }
    if (@frames && $quote eq '' && $char eq '(') {
      $frames[-1]{depth}++;
      next;
    }
    if (@frames && $quote eq '' && $char eq ')') {
      $frames[-1]{depth}--;
      if ($frames[-1]{depth} == 0) {
        my $frame = pop @frames;
        $quote = $frame->{quote};
      }
      next;
    }
    next unless $quote eq '' && $char eq '<' && substr($line, $i + 1, 1) eq '<';
    if (@frames) {
      print STDERR "$path:$line_number\n";
      exit 1;
    }

    my $j = $i + 2;
    my $strip_tabs = substr($line, $j, 1) eq '-';
    $j++ if $strip_tabs;
    $j++ while substr($line, $j, 1) =~ /[ \t]/;
    my $delimiter = '';
    my $delimiter_quote = '';
    for (; $j < $length; $j++) {
      my $token = substr($line, $j, 1);
      if ($delimiter_quote) {
        if ($token eq $delimiter_quote) {
          $delimiter_quote = '';
        } elsif ($token eq '\\' && $delimiter_quote eq '"') {
          $j++;
          $delimiter .= substr($line, $j, 1);
        } else {
          $delimiter .= $token;
        }
        next;
      }
      if ($token eq "'" || $token eq '"') {
        $delimiter_quote = $token;
        next;
      }
      if ($token eq '\\') {
        $j++;
        $delimiter .= substr($line, $j, 1);
        next;
      }
      last if $token =~ /[\s;|&()<>]/;
      $delimiter .= $token;
    }
    push @heredocs, { delimiter => $delimiter, strip_tabs => $strip_tabs };
    $i = $j - 1;
  }
}

exit 0;
PERL
}

test_help_includes_entire_header() {
  local help
  help=$("$ROOT/bin/fm-brief.sh" --help)
  assert_contains "$help" "Refuses to overwrite an existing brief." "fm-brief.sh --help omitted its header terminator"
  pass "fm-brief.sh: --help renders the complete header"
}

# Registry with one project per delivery mode, so each ship-mode DOD branch is
# exercised. A project absent from the registry defaults to no-mistakes.
write_registry() {
  local home=$1
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- direct-proj [direct-PR] - fixture for direct-PR mode (added 2026-07-01)
- local-proj [local-only] - fixture for local-only mode (added 2026-07-01)
EOF
}

# fm-brief.sh must exit 0 and produce a brief with no unreplaced shell
# metacharacter corruption for every ship delivery mode. This also guards
# against any *new* unescaped apostrophe or unbalanced quote later added to
# one of these DOD blocks, since a broken heredoc corrupts or empties the
# generated brief content, not just the script's own syntax.
test_ship_modes_generate_clean_briefs() {
  local home id brief status
  home="$TMP_ROOT/ship-home"
  write_registry "$home"

  for id_proj in "brief-nomistakes-a1:no-registry-proj" "brief-directpr-a2:direct-proj" "brief-localonly-a3:local-proj"; do
    id=${id_proj%%:*}
    proj=${id_proj##*:}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "$proj" >/dev/null 2>&1; status=$?
    expect_code 0 "$status" "fm-brief.sh $id $proj should exit 0"
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    assert_grep "# Definition of done" "$brief" "$id: brief missing Definition of done section"
    assert_grep "{TASK}" "$brief" "$id: brief missing the {TASK} placeholder"
    assert_grep "mid-task \`working:\` line (including setup complete) is nonterminal" "$brief" \
      "$id: brief missing nonterminal working:/setup-complete gate protection"
    assert_no_grep "EOF" "$brief" "$id: brief leaked a heredoc EOF marker (unterminated heredoc)"
  done
  pass "fm-brief.sh: no-mistakes/direct-PR/local-only briefs generate cleanly"
}

test_faster_paths_use_configured_authority_without_stacked_review() {
  local home id brief
  home="$TMP_ROOT/configured-authority-home"
  write_registry "$home"
  id="brief-direct-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority decides whether to merge the PR; firstmate relays the outcome." "$brief" \
    "direct-PR brief lost configured merge authority"
  assert_no_grep "The captain reviews and merges the PR" "$brief" \
    "direct-PR brief hard-coded captain-only authority"
  id="brief-local-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" local-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "the configured merge authority approves before firstmate merges it into the local default branch through the guarded fast-forward path" "$brief" \
    "local-only brief lost configured merge authority on the remote-less landing"
  assert_no_grep "The captain approves the ready branch" "$brief" \
    "local-only brief hard-coded captain-only authority"
  assert_no_grep "Firstmate then reviews your branch diff" "$brief" \
    "local-only brief retained firstmate's own review stacked on the selected delivery path"
  pass "fm-brief.sh: faster paths use configured authority without stacked review"
}

# The delivery contract that this whole mode exists to carry: the worker publishes
# its branch and stops short of the merge request. The historical "never push" and
# "no remote, no PR, no pipeline" wording is what silently stranded finished
# branches, so its absence is asserted as directly as its replacement.
test_local_only_brief_publishes_and_stops_before_the_merge_request() {
  local home id brief
  home="$TMP_ROOT/publish-home"
  write_registry "$home"
  id="brief-local-publish-p1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" local-proj --branch feature/JUSTMD-9 >/dev/null 2>&1
  brief="$home/data/$id/brief.md"

  assert_no_grep "Never push to any remote" "$brief" \
    "local-only brief still forbids pushing, which strands the finished branch"
  assert_no_grep "no remote, no PR, no pipeline" "$brief" \
    "local-only brief still declares the mode unpublished and unvalidated"
  assert_no_grep "Do NOT push" "$brief" "local-only brief still forbids the publication step"
  assert_grep "publish your branch" "$brief" "local-only brief does not instruct publication"
  assert_grep 'done: branch feature/JUSTMD-9 published' "$brief" \
    "local-only brief has no publication completion gate naming the branch"
  assert_grep "Do NOT open a PR or merge request" "$brief" \
    "local-only brief does not forbid opening the merge request"
  assert_grep 'separate "ship it" word' "$brief" \
    "local-only brief does not say who authorises the merge request later"
  pass "fm-brief.sh: local-only brief publishes the branch and forbids the merge request"
}

# Validation runs, and it runs in the shape that stops before publication: the
# pipeline's own push step is what publishes, so a delivery run must skip it along
# with the merge-request and CI steps that belong to the later ship-it stage.
test_local_only_brief_runs_the_pipeline_stopping_before_publication() {
  local home id brief
  home="$TMP_ROOT/pipeline-home"
  write_registry "$home"
  id="brief-local-pipeline-p2"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" local-proj --branch feature/JUSTMD-9 >/dev/null 2>&1
  brief="$home/data/$id/brief.md"

  assert_grep "--skip push,pr,ci" "$brief" \
    "local-only brief does not stop the validation run before publication"
  assert_grep "--skip review,test,document,lint,pr,ci" "$brief" \
    "local-only brief does not publish through the pipeline's own push step alone, so a fix commit could reach the remote unreviewed"
  assert_grep "no-mistakes axi run --help" "$brief" \
    "local-only brief does not send the worker to the authoritative flag reference"
  assert_grep "Run \`no-mistakes doctor\`" "$brief" \
    "local-only brief lost the pipeline initialization step it now needs"
  assert_grep "ask-user findings are never yours to answer" "$brief" \
    "local-only brief lost the gate-driving contract that pipeline modes share"
  pass "fm-brief.sh: local-only brief validates with publication skipped"
}

# The review stage cannot be skipped silently: publication is gated on the
# verifier, and a refusal is a stop-and-report outcome rather than a warning the
# worker may publish through.
test_local_only_brief_gates_publication_on_the_independent_review() {
  local home id brief
  home="$TMP_ROOT/review-gate-home"
  write_registry "$home"
  id="brief-local-gate-p3"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" local-proj --branch feature/JUSTMD-9 >/dev/null 2>&1
  brief="$home/data/$id/brief.md"

  assert_grep "fm-craft-review.sh' verify $id" "$brief" \
    "local-only brief does not gate publication on the review verifier"
  assert_grep "If it refuses, do NOT publish" "$brief" \
    "local-only brief lets the worker publish through a refused review"
  assert_grep "reviewer that did not write this code" "$brief" \
    "local-only brief does not require an independent reviewer"
  assert_grep "Do not review your own work" "$brief" \
    "local-only brief lets the worker review itself"
  assert_grep "every new commit needs a fresh one" "$brief" \
    "local-only brief does not say the review is pinned to its commit"
  pass "fm-brief.sh: local-only brief gates publication on the independent review"
}

# A brief that promises a stage which will not run is how a worker ends up
# waiting for a reviewer nobody will send. On a project this home does not
# review, the local-only brief must describe the delivery that actually happens:
# implement, validate, publish - with no review stop and no publication gate.
test_local_only_brief_omits_the_review_where_it_is_not_required() {
  local home id brief
  home="$TMP_ROOT/review-scope-home"
  write_registry "$home"
  mkdir -p "$home/config"
  printf '# this home reviews only these projects\nsome-other-project\n' \
    > "$home/config/craft-review-projects"
  id="brief-local-unscoped-p9"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" local-proj --branch feature/JUSTMD-11 >/dev/null 2>&1
  brief="$home/data/$id/brief.md"

  assert_grep "does not run the independent craftsmanship review on this project" "$brief" \
    "brief does not tell the worker there is no reviewer coming"
  assert_grep "Do not wait for one" "$brief" \
    "brief does not tell the worker not to wait for a reviewer"
  assert_no_grep "fm-craft-review.sh' verify" "$brief" \
    "brief still gates publication on a verdict no reviewer will record"
  assert_no_grep "ready for craftsmanship review" "$brief" \
    "brief still stops the worker for a review that will not happen"
  # The rest of the delivery is unchanged: validate without publishing, then
  # publish the branch and open nothing.
  assert_grep "skip push,pr,ci" "$brief" \
    "brief lost the validation run that skips publication"
  assert_grep "skip review,test,document,lint,pr,ci" "$brief" \
    "brief lost the publication step"
  assert_grep "Do NOT open a PR or merge request" "$brief" \
    "brief lost the merge-request boundary"
  pass "fm-brief.sh: local-only brief omits the review where this home does not require it"
}

# A brief must never quietly omit a safety stage because a check failed to run.
# Only the scope decision's own "no" drops the review; a question that could not
# be asked keeps every stage.
test_local_only_brief_keeps_the_review_when_the_scope_check_fails() {
  local home root id brief
  home="$TMP_ROOT/review-scope-broken-home"
  root="$TMP_ROOT/review-scope-broken-root"
  write_registry "$home"
  mkdir -p "$home/config" "$root"
  # This home would drop the review if the answer were readable at all.
  printf 'some-other-project\n' > "$home/config/craft-review-projects"
  cp -R "$ROOT/bin" "$root/bin"
  cat > "$root/bin/fm-craft-review.sh" <<'SH'
#!/usr/bin/env bash
echo "error: cannot answer" >&2
exit 2
SH
  chmod +x "$root/bin/fm-craft-review.sh"
  id="brief-local-scope-broken-p11"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    "$ROOT/bin/fm-brief.sh" "$id" local-proj --branch feature/JUSTMD-13 >/dev/null 2>&1
  brief="$home/data/$id/brief.md"

  [ -f "$brief" ] || fail "no brief was generated when the scope check could not answer"
  assert_grep "reviewer that did not write this code" "$brief" \
    "an unanswerable scope check dropped the review stage"
  assert_no_grep "does not run the independent craftsmanship review" "$brief" \
    "an unanswerable scope check was read as a no"
  pass "fm-brief.sh: an unanswerable scope check keeps the review rather than dropping it"
}

# The same registry entry, with this home requiring the review, keeps every
# stage - so the difference is the configuration and nothing else.
test_local_only_brief_keeps_the_review_where_it_is_required() {
  local home id brief
  home="$TMP_ROOT/review-scope-in-home"
  write_registry "$home"
  mkdir -p "$home/config"
  printf 'local-proj\n' > "$home/config/craft-review-projects"
  id="brief-local-scoped-p10"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" local-proj --branch feature/JUSTMD-12 >/dev/null 2>&1
  brief="$home/data/$id/brief.md"

  assert_grep "fm-craft-review.sh' verify $id" "$brief" \
    "a listed project's brief lost the publication gate"
  assert_grep "reviewer that did not write this code" "$brief" \
    "a listed project's brief lost the independent reviewer"
  pass "fm-brief.sh: local-only brief keeps the review where this home requires it"
}

# The brief decides which stages to promise from the DISPATCHING home's scope
# file, but the gate it hands the worker runs as a crewmate outside that home,
# where FM_HOME resolves to the code root instead. Unless the generated command
# pins the config home the way it already pins the state dir, a code-root scope
# file that omits the project makes `verify` stand aside on a home that requires
# the review, and an unreviewed commit publishes.
test_local_only_publication_gate_reads_the_dispatching_homes_scope() {
  local home root id brief cmd out status
  home="$TMP_ROOT/review-scope-crewmate-home"
  root="$TMP_ROOT/review-scope-crewmate-root"
  write_registry "$home"
  mkdir -p "$home/config" "$home/state" "$root/config"
  # This home requires the review; the code root the crewmate would otherwise
  # resolve says the opposite.
  printf 'local-proj\n' > "$home/config/craft-review-projects"
  printf 'some-other-project\n' > "$root/config/craft-review-projects"
  cp -R "$ROOT/bin" "$root/bin"

  fm_git_worktree "$home/local-proj" "$home/wt" feature/JUSTMD-14
  id="brief-local-crewmate-p12"
  fm_write_meta "$home/state/$id.meta" \
    "worktree=$home/wt" \
    "project=$home/local-proj" \
    "mode=local-only" \
    "kind=ship"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    "$ROOT/bin/fm-brief.sh" "$id" local-proj --branch feature/JUSTMD-14 >/dev/null 2>&1
  brief="$home/data/$id/brief.md"

  cmd=$(grep -o "FM_STATE_OVERRIDE=[^\`]*verify $id" "$brief" | head -1)
  [ -n "$cmd" ] || fail "the brief promised no publication gate for a home that requires the review"
  # Exactly how a crewmate runs it: outside the dispatching home, with none of
  # this home's environment inherited.
  out=$(env -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE \
    bash -c "$cmd" 2>&1); status=$?
  expect_code 1 "$status" "the gate let an unreviewed commit publish from outside the dispatching home"
  assert_contains "$out" "has no craftsmanship review" \
    "the gate did not refuse the unreviewed commit it was pointed at"
  case "$out" in
    *"not required"*)
      fail "the gate read the code root's scope file instead of the dispatching home's" ;;
  esac
  pass "fm-brief.sh: the publication gate resolves the dispatching home's scope file, not the code root's"
}

test_craft_review_brief_states_its_remit_and_boundaries() {
  local home id brief status
  home="$TMP_ROOT/craft-home"
  write_registry "$home"
  id="brief-craft-c1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" local-proj --craft-review brief-local-publish-p1 >/dev/null 2>&1
  status=$?
  expect_code 0 "$status" "craft-review brief should scaffold cleanly"
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "craft-review brief was not scaffolded"
  assert_no_grep "EOF" "$brief" "craft-review brief leaked a heredoc EOF marker"

  assert_grep "craftsmanship-review/SKILL.md" "$brief" \
    "craft-review brief does not point the reviewer at its remit"
  assert_grep "blocked: craftsmanship review remit is unreadable" "$brief" \
    "craft-review brief lets an unreadable remit pass as a review"
  assert_grep "NOT a defect hunt" "$brief" \
    "craft-review brief does not separate its remit from the pipeline's review step"
  assert_grep "never publish, never open a PR, and never merge" "$brief" \
    "craft-review brief does not forbid the reviewer publishing or merging"
  assert_grep "You never edit the code you review" "$brief" \
    "craft-review brief lets the reviewer rewrite the code instead of reporting findings"
  assert_grep "fm-review-diff.sh' brief-local-publish-p1" "$brief" \
    "craft-review brief does not tell the reviewer how to read the work under review"
  assert_grep "fm-craft-review.sh' record brief-local-publish-p1 --reviewer $id" "$brief" \
    "craft-review brief does not have the reviewer record its verdict"
  pass "fm-brief.sh: craft-review brief carries its remit pointer and hard boundaries"
}

# One story keeps one checkout: the reviewer reads in the implementing task's own
# worktree rather than taking one of its own. That is only safe while the reviewer
# writes nothing there and the two agents are serialised, so the brief must say both.
test_craft_review_brief_shares_the_implementers_worktree_read_only() {
  local home id brief
  home="$TMP_ROOT/craft-colocation-home"
  write_registry "$home"
  id="brief-craft-colocated-c4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" local-proj --craft-review brief-local-publish-p1 >/dev/null 2>&1
  brief="$home/data/$id/brief.md"

  assert_grep "in task brief-local-publish-p1's OWN worktree" "$brief" \
    "craft-review brief does not put the reviewer in the implementer's worktree"
  assert_no_grep "disposable git worktree" "$brief" \
    "craft-review brief still gives the reviewer a checkout of its own"
  assert_grep "Task brief-local-publish-p1 is idle while you work" "$brief" \
    "craft-review brief does not serialise the two agents"
  assert_grep "**Write nothing in this worktree.**" "$brief" \
    "craft-review brief does not forbid writing in the shared worktree"
  assert_grep "git status --porcelain" "$brief" \
    "craft-review brief does not have the reviewer check the tree is clean on arrival"
  assert_grep "not a commit, not a branch, not a stash" "$brief" \
    "craft-review brief does not name the git writes that would corrupt the shared branch"
  pass "fm-brief.sh: craft-review brief shares the implementer's worktree read-only"
}

test_craft_review_refuses_to_review_its_own_task() {
  local home id out status
  home="$TMP_ROOT/craft-self-home"
  write_registry "$home"
  id="brief-craft-self-c2"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" local-proj --craft-review "$id" 2>&1); status=$?
  expect_code 1 "$status" "a self-reviewing craft-review brief must be refused"
  assert_contains "$out" "cannot review its own task" \
    "refusal should say the reviewer must be a separate task"
  assert_absent "$home/data/$id/brief.md" "no brief should be written for a self-review"

  out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-craft-noval-c3 local-proj --craft-review 2>&1); status=$?
  expect_code 1 "$status" "--craft-review without a reviewed task id must be refused"
  assert_contains "$out" "requires the reviewed task id" \
    "refusal should name the missing reviewed task id"
  pass "fm-brief.sh: --craft-review refuses a self-review and a missing task id"
}

# Pin the specific line the bug lived on: the no-mistakes DOD's no-mistakes
# reference must render as plain prose with no dangling apostrophe artifact.
test_no_mistakes_dod_wording() {
  local home id brief
  home="$TMP_ROOT/wording-home"
  mkdir -p "$home/data"
  id="brief-wording-b1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "no-mistakes itself provides for the mechanics" "$brief" \
    "no-mistakes DOD lost its guidance-reference sentence"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`no-mistakes axi run --help`' "$brief" \
    "no-mistakes DOD must render literal backticks around the help command"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`help`' "$brief" \
    "no-mistakes DOD must render literal backticks around help"
  # The apostrophe in "firstmate's authority check" is now structurally safe
  # (no `$(...)` wrapper around the heredoc), so it renders verbatim instead of
  # being reworded or escaped away. test_no_heredoc_in_command_substitution
  # guards the structure that makes it safe.
  assert_grep "firstmate's authority check" "$brief" \
    "no-mistakes DOD lost the apostrophe prose that the structural fix makes parse-safe"
  pass "fm-brief.sh: no-mistakes DOD keeps its apostrophe prose, now parse-safe"
}

test_ship_project_memory_wording() {
  local home id brief
  home="$TMP_ROOT/project-memory-home"
  mkdir -p "$home/data"
  id="brief-memory-c1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "Record only project knowledge useful to almost every future session." "$brief" \
    "project-memory contract lost the durable-knowledge bar"
  assert_grep "prefer a pointer to the authoritative file, command, or doc over copying the detail" "$brief" \
    "project-memory contract lost pointer-over-copy guidance"
  assert_grep "lacks \`## Maintaining this file\`, add that short self-governance section" "$brief" \
    "project-memory contract lost the self-governance add-in-same-pass rule"
  pass "fm-brief.sh: ship project-memory wording carries the AGENTS.md authoring bar"
}

test_herdr_lab_contract_is_explicit_and_complete() {
  local home id brief
  home="$TMP_ROOT/herdr-lab-home"
  mkdir -p "$home/data"
  id="brief-herdr-lab-d1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "Herdr lab brief was not scaffolded"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "Herdr lab brief missing its hard safety contract"
  assert_grep "HERDR_LAB_HELPER='$ROOT/bin/fm-herdr-lab.sh'" "$brief" \
    "Herdr lab brief must bind the absolute Firstmate helper path"
  assert_grep "HERDR_LAB_SESSION=\$(\"\$HERDR_LAB_HELPER\" name $id)" "$brief" \
    "Herdr lab brief missing helper-owned session naming"
  assert_grep "\"\$HERDR_LAB_HELPER\" provision \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned provisioning"
  assert_grep "\"\$HERDR_LAB_HELPER\" teardown \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned teardown"
  assert_grep "required trailing \`--session \"\$HERDR_LAB_SESSION\"\`" "$brief" \
    "Herdr lab brief missing the per-call trailing session contract"
  assert_grep "direct \`herdr server stop\`" "$brief" \
    "Herdr lab brief missing the forbidden server-global command list"
  assert_grep "records the live default session before provisioning" "$brief" \
    "Herdr lab brief missing the before tripwire"
  assert_grep "verifies the identical fleet state after teardown" "$brief" \
    "Herdr lab brief missing the after tripwire"
  assert_no_grep "Herdr lifecycle declaration - NOT ENABLED" "$brief" \
    "Herdr lab brief retained the unguarded declaration"
  pass "fm-brief.sh: --herdr-lab emits the complete hard safety contract"
}

test_herdr_lab_contract_quotes_foreign_firstmate_path() {
  local home id brief foreign_root helper
  home="$TMP_ROOT/herdr-lab-foreign-home"
  foreign_root="$TMP_ROOT/firstmate helper's root"
  mkdir -p "$home/data"
  id="brief-herdr-lab-foreign-d2"
  helper=$(printf '%s' "$foreign_root/bin/fm-herdr-lab.sh" | sed "s/'/'\\\\''/g")
  helper="'$helper'"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$foreign_root" "$ROOT/bin/fm-brief.sh" "$id" foreign --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "HERDR_LAB_HELPER=$helper" "$brief" \
    "Herdr lab brief must shell-quote an absolute Firstmate helper path"
  assert_no_grep "bin/fm-herdr-lab.sh name $id" "$brief" \
    "Herdr lab brief must not invoke a worktree-relative helper"
  pass "fm-brief.sh: --herdr-lab uses its quoted Firstmate-owned helper path"
}

test_herdr_lab_omission_is_loud_for_ship_and_scout() {
  local home id brief
  home="$TMP_ROOT/herdr-gate-home"
  mkdir -p "$home/data"
  for kind in ship scout; do
    id="brief-herdr-gate-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_grep "# Herdr lifecycle declaration - NOT ENABLED" "$brief" \
      "$kind brief silently omitted the Herdr declaration"
    assert_grep "regenerate the brief with \`--herdr-lab\` before dispatch" "$brief" \
      "$kind brief missing the fail-visible regeneration instruction"
  done
  pass "fm-brief.sh: ship and scout scaffolds make omitted Herdr intent fail-visible"
}

test_secondmate_no_projects_charter() {
  local home brief status
  home="$TMP_ROOT/no-projects-home"
  mkdir -p "$home/data"

  # The deliberate --no-projects signal scaffolds a valid project-less charter for
  # a domain whose subject is the firstmate repo itself (no clones needed).
  FM_HOME="$home" FM_SECONDMATE_CHARTER='firstmate self-development' \
    FM_SECONDMATE_SCOPE='firstmate repo work' \
    "$ROOT/bin/fm-brief.sh" fdev --secondmate --no-projects >/dev/null 2>&1; status=$?
  expect_code 0 "$status" "--no-projects secondmate brief should exit 0"
  brief="$home/data/fdev/brief.md"
  assert_present "$brief" "project-less charter was not scaffolded"
  assert_grep "# Project clones" "$brief" "project-less charter dropped the Project clones heading"
  assert_grep "None. This is a project-less domain" "$brief" \
    "project-less charter did not render a sensible no-clones note"
  assert_grep "its crews take pooled worktrees of that repo" "$brief" \
    "project-less charter operating model lost the pooled-worktree note"
  assert_no_grep "The projects above are local clones" "$brief" \
    "project-less charter kept the with-projects operating-model line"
  assert_grep 'working [key=<work-slug>]' "$brief" \
    "secondmate charter did not key material routed-work phases"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "secondmate charter did not close a quietly ended routed-work phase"
  assert_grep 'use the same key on its later' "$brief" \
    "secondmate charter did not supersede working phases with later states"
  if grep -nE '^-[[:space:]]*$' "$brief" >/dev/null; then
    fail "project-less charter left a stray empty project bullet"
  fi

  # Accidental omission (no projects, no signal) still fails loudly, writing nothing.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops --secondmate >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "secondmate brief with no projects and no --no-projects must fail"
  assert_absent "$home/data/oops/brief.md" "loud-failure secondmate brief still wrote a file"

  # --no-projects is mutually exclusive with a project list.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops2 --secondmate --no-projects alpha >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects combined with a project list must fail"

  # --no-projects applies only to secondmate charters, never a ship/scout brief.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" oops3 somerepo --no-projects >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects on a ship brief must fail"

  pass "fm-brief.sh: --no-projects scaffolds a project-less charter and guards misuse"
}

test_secondmate_marked_request_reporting_contract() {
  local home brief
  home="$TMP_ROOT/marked-request-reporting-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=paused \
    FM_SECONDMATE_CHARTER='Handle routed domain work.' \
    "$ROOT/bin/fm-brief.sh" marked-request-reporting --secondmate --no-projects >/dev/null 2>&1
  brief="$home/data/marked-request-reporting/brief.md"

  assert_grep 'A marked request requires one correlated answer after the work' "$brief" \
    "secondmate charter did not require the correlated answer after the work"
  assert_grep 'does not require a separate receipt or start acknowledgement' "$brief" \
    "secondmate charter did not reject a separate receipt/start acknowledgement"
  assert_grep "Never append \`working:\` merely to acknowledge receipt or announce that a marked request has started." "$brief" \
    "secondmate charter did not forbid a generic working acknowledgement"
  assert_no_grep "Give every routed-work phase a stable key: open it with \`working" "$brief" \
    "secondmate charter retained the unconditional working opener"
  assert_grep 'When a routed-work phase has a supervisor-actionable material change worth reporting under the rule above' "$brief" \
    "secondmate charter did not limit keyed phases to reportable material changes"
  assert_grep "If its first reportable event is \`working [key=<work-slug>]: {material phase}\`" "$brief" \
    "secondmate charter lost keyed working syntax for a reportable material phase"
  assert_grep "use the same key on its later \`paused\`, \`done\`, \`failed\`, \`needs-decision\`, or \`blocked\` event" "$brief" \
    "secondmate charter lost same-key closure for a reportable material phase"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "secondmate charter lost resolved closure for a keyed material phase"

  assert_grep 'include that exact token in your parent status reply' "$brief" \
    "secondmate charter lost correlated parent results"
  assert_grep 'For a terse result, a status line is the whole answer.' "$brief" \
    "secondmate charter lost terse result reporting"
  assert_grep 'append a status line that points to that doc' "$brief" \
    "secondmate charter lost detailed document pointers"
  assert_grep 'Report only true captain-relevant outcomes or a declared external wait' "$brief" \
    "secondmate charter lost declared external waits"
  assert_grep 'a captain decision, a real blocker, a failure, or work ready for review' "$brief" \
    "secondmate charter lost decisions, blockers, failures, or ready outcomes"
  assert_grep 'States: working, needs-decision, blocked, paused, done, failed.' "$brief" \
    "secondmate charter changed the preserved status vocabulary"
  pass "fm-brief.sh: marked requests avoid generic acknowledgements and preserve material reporting"
}

test_secondmate_directory_paths_are_absolute_and_output_is_stable() {
  local root home data_override state_override brief baseline err status
  root="$TMP_ROOT/relative-directory-inputs"
  mkdir -p "$root"
  root=$(cd "$root" && pwd -P)
  home="$root/home"
  data_override="$root/data-override"
  state_override="$root/state-override"
  mkdir -p "$home/data" "$home/state" "$data_override" "$state_override" \
    "$root/cdpath/home/data" "$root/cdpath/home/state" \
    "$root/cdpath/data-override" "$root/cdpath/state-override"

  brief="$home/data/relative-home/brief.md"
  FM_HOME="$home" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" relative-home --secondmate --no-projects >/dev/null 2>&1
  baseline="$root/absolute-home-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME=home FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" relative-home --secondmate --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative FM_HOME changed charter bytes compared with the same absolute home"
  assert_grep ">> '$home/state/relative-home.status'" "$brief" \
    "relative FM_HOME did not render an absolute secondmate status path"

  brief="$home/data/relative-state/brief.md"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state_override" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" relative-state --secondmate --no-projects >/dev/null 2>&1
  baseline="$root/absolute-state-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME="$home" FM_STATE_OVERRIDE=state-override FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" relative-state --secondmate --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative FM_STATE_OVERRIDE changed charter bytes compared with the same absolute state directory"
  assert_grep ">> '$state_override/relative-state.status'" "$brief" \
    "relative FM_STATE_OVERRIDE did not render an absolute secondmate status path"

  brief="$data_override/relative-data/brief.md"
  FM_HOME="$home" FM_DATA_OVERRIDE="$data_override" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" relative-data --secondmate --no-projects >/dev/null 2>&1
  baseline="$root/absolute-data-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME="$home" FM_DATA_OVERRIDE=data-override FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" relative-data --secondmate --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative FM_DATA_OVERRIDE changed charter bytes compared with the same absolute data directory"
  assert_grep ">> '$home/state/relative-data.status'" "$brief" \
    "relative FM_DATA_OVERRIDE changed the absolute default status path"

  err="$root/unresolved.err"
  (
    cd "$root" || exit 1
    FM_HOME=missing-home FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" unresolved-home --secondmate --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative FM_HOME must fail"
  assert_grep "FM_HOME directory cannot be resolved: missing-home" "$err" \
    "unresolved relative FM_HOME did not fail loudly"

  (
    cd "$root" || exit 1
    FM_HOME="$home" FM_STATE_OVERRIDE=missing-state FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" unresolved-state --secondmate --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative FM_STATE_OVERRIDE must fail"
  assert_grep "FM_STATE_OVERRIDE directory cannot be resolved: missing-state" "$err" \
    "unresolved relative FM_STATE_OVERRIDE did not fail loudly"

  (
    cd "$root" || exit 1
    FM_HOME="$home" FM_DATA_OVERRIDE=missing-data FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" unresolved-data --secondmate --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative FM_DATA_OVERRIDE must fail"
  assert_grep "FM_DATA_OVERRIDE directory cannot be resolved: missing-data" "$err" \
    "unresolved relative FM_DATA_OVERRIDE did not fail loudly"

  pass "fm-brief.sh: relative directory inputs ignore CDPATH, render stable absolute charter paths, or fail loudly"
}

test_herdr_lab_contract_applies_to_scouts_but_not_secondmates() {
  local home brief status=0
  home="$TMP_ROOT/herdr-kind-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" herdr-scout firstmate --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/herdr-scout/brief.md"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "scout --herdr-lab brief missing the contract"

  FM_HOME="$home" FM_SECONDMATE_CHARTER=ops "$ROOT/bin/fm-brief.sh" herdr-secondmate --secondmate firstmate --herdr-lab >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "secondmate --herdr-lab must be rejected"
  assert_absent "$home/data/herdr-secondmate/brief.md" \
    "rejected secondmate --herdr-lab still wrote a brief"
  pass "fm-brief.sh: Herdr lab contract covers scouts and rejects secondmate misuse"
}

test_pause_verb_override_renders_all_brief_scaffolds() {
  local home kind id brief
  home="$TMP_ROOT/pause-verb-home"
  mkdir -p "$home/data"

  for kind in ship scout secondmate; do
    id="brief-pause-verb-$kind"
    case "$kind" in
      ship)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate >/dev/null 2>&1
        ;;
      scout)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
        ;;
      secondmate)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" --secondmate --no-projects >/dev/null 2>&1
        ;;
    esac
    brief="$home/data/$id/brief.md"
    assert_grep "States: working, needs-decision, blocked, awaiting, done, failed." "$brief" \
      "$kind brief did not render the configured pause verb in its states list"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_grep 'Use `awaiting: {why}`' "$brief" \
      "$kind brief did not instruct the configured pause status"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_no_grep '`paused: {why}`' "$brief" \
      "$kind brief still instructs the default paused status"
    assert_grep 'or a blocker clears' "$brief" \
      "$kind brief did not require durable resolution when a blocker clears"
  done
  pass "fm-brief.sh: custom pause verb renders in every scaffold"
}

test_ship_branch_defaults_to_loud_placeholder() {
  local home id brief
  home="$TMP_ROOT/branch-default-home"
  mkdir -p "$home/data"
  id="brief-branch-default-e1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_no_grep "fm/$id" "$brief" \
    "ship brief still hardcodes an fm/<id> branch default"
  assert_grep 'git checkout -b {BRANCH}' "$brief" \
    "an omitted --branch must render a loud {BRANCH} placeholder, not a silent default"
  pass "fm-brief.sh: an omitted ship branch name is a loud placeholder, never a silent fm/<id> default"
}

test_ship_branch_flag_lands_verbatim() {
  local home id brief
  home="$TMP_ROOT/branch-flag-home"
  write_registry "$home"
  id="brief-branch-flag-e2"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj --branch feature/JUSTMD-123 >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep 'git checkout -b feature/JUSTMD-123' "$brief" \
    "--branch value did not land verbatim in the setup step"
  # shellcheck disable=SC2016 # literal backticks from the brief text, not command substitution
  assert_grep 'push only your `feature/JUSTMD-123` branch' "$brief" \
    "--branch value did not land verbatim in the direct-PR rule"
  assert_no_grep '{BRANCH}' "$brief" \
    "a supplied --branch left the loud placeholder behind"
  assert_no_grep "fm/$id" "$brief" \
    "a supplied --branch still left the old fm/<id> default in the brief"

  id="brief-branch-flag-local-e3"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" local-proj --branch chore/JUSTMD-9 >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep 'git checkout -b chore/JUSTMD-9' "$brief" \
    "--branch value did not land verbatim in the local-only setup step"
  assert_grep 'ready in branch chore/JUSTMD-9' "$brief" \
    "--branch value did not land verbatim in the local-only done instruction"
  pass "fm-brief.sh: a supplied --branch name lands verbatim across ship modes"
}

test_ship_branch_flag_rejected_outside_ship() {
  local home status=0
  home="$TMP_ROOT/branch-misuse-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" branch-misuse-scout firstmate --scout --branch feature/JUSTMD-1 \
    >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "--branch on a scout brief must fail"
  assert_absent "$home/data/branch-misuse-scout/brief.md" \
    "rejected --branch on a scout brief still wrote a file"

  status=0
  FM_HOME="$home" FM_SECONDMATE_CHARTER=x "$ROOT/bin/fm-brief.sh" branch-misuse-sm --secondmate --no-projects \
    --branch feature/JUSTMD-1 >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "--branch on a secondmate charter must fail"
  pass "fm-brief.sh: --branch is rejected outside ship briefs"
}

test_co_author_prohibition_in_every_variant() {
  local home id brief
  home="$TMP_ROOT/co-author-home"
  mkdir -p "$home/data"

  id="brief-co-author-ship-f1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --branch feature/JUSTMD-1 >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep 'Co-authored-by:' "$brief" "ship brief missing co-author prohibition"
  assert_grep 'git log -1' "$brief" "ship brief missing the trailer-verification command"

  id="brief-co-author-scout-f2"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep 'Co-authored-by:' "$brief" "scout brief missing co-author prohibition"

  id="brief-co-author-herdr-f3"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --herdr-lab --branch feature/JUSTMD-2 >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep 'Co-authored-by:' "$brief" "--herdr-lab ship brief missing co-author prohibition"

  FM_HOME="$home" FM_SECONDMATE_CHARTER='ops' "$ROOT/bin/fm-brief.sh" brief-co-author-sm-f4 --secondmate --no-projects \
    >/dev/null 2>&1
  brief="$home/data/brief-co-author-sm-f4/brief.md"
  assert_grep 'Co-authored-by:' "$brief" "secondmate charter missing co-author prohibition"
  pass "fm-brief.sh: every brief variant forbids agent co-author trailers"
}

test_scout_and_secondmate_load_decision_hold_policy() {
  local home scout charter
  home="$TMP_ROOT/decision-policy-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-brief.sh" sample-investigation sample --scout >/dev/null 2>&1
  scout="$home/data/sample-investigation/brief.md"
  assert_grep "$ROOT/.agents/skills/decision-hold-lifecycle/SKILL.md" "$scout" \
    "scout brief did not load the unresolved-decision policy before done"
  assert_grep "pass its shared completion gate for the report and any visual review" "$scout" \
    "scout brief did not cross-reference visual-review completion"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SECONDMATE_CHARTER='sample reviews' \
    "$ROOT/bin/fm-brief.sh" sample-mate --secondmate --no-projects >/dev/null 2>&1
  charter="$home/data/sample-mate/brief.md"
  assert_grep "load \`decision-hold-lifecycle\`" "$charter" \
    "secondmate charter did not load the shared decision policy for detailed investigations"
  pass "fm-brief.sh: investigation and visual-review completions load the shared decision policy"
}

# Scout and secondmate paths still scaffold well-formed briefs.
test_scout_and_secondmate_scaffold() {
  local brief
  FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-scout-q6 alpha --scout >/dev/null 2>&1 \
    || fail "fm-brief.sh scout scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-scout-q6/brief.md"
  assert_present "$brief" "scout brief was not scaffolded"
  assert_grep "SCOUT task" "$brief" "scout brief must declare itself a scout task"
  assert_grep "report.md" "$brief" "scout brief must point at the report deliverable"

  FM_SECONDMATE_CHARTER='Supervise the alpha domain.' \
    FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-sm-q6 --secondmate alpha >/dev/null 2>&1 \
    || fail "fm-brief.sh secondmate scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-sm-q6/brief.md"
  assert_present "$brief" "secondmate charter was not scaffolded"
  assert_grep "persistent second mate" "$brief" \
    "secondmate charter must declare its role"
  pass "fm-brief: scout and secondmate code paths still scaffold well-formed briefs"
}

test_script_parses
test_no_heredoc_in_command_substitution
test_help_includes_entire_header
test_ship_modes_generate_clean_briefs
test_faster_paths_use_configured_authority_without_stacked_review
test_local_only_brief_publishes_and_stops_before_the_merge_request
test_local_only_brief_runs_the_pipeline_stopping_before_publication
test_local_only_brief_gates_publication_on_the_independent_review
test_local_only_brief_omits_the_review_where_it_is_not_required
test_local_only_brief_keeps_the_review_when_the_scope_check_fails
test_local_only_brief_keeps_the_review_where_it_is_required
test_local_only_publication_gate_reads_the_dispatching_homes_scope
test_craft_review_brief_states_its_remit_and_boundaries
test_craft_review_brief_shares_the_implementers_worktree_read_only
test_craft_review_refuses_to_review_its_own_task
test_no_mistakes_dod_wording
test_ship_project_memory_wording
test_herdr_lab_contract_is_explicit_and_complete
test_herdr_lab_contract_quotes_foreign_firstmate_path
test_herdr_lab_omission_is_loud_for_ship_and_scout
test_herdr_lab_contract_applies_to_scouts_but_not_secondmates
test_secondmate_no_projects_charter
test_secondmate_marked_request_reporting_contract
test_secondmate_directory_paths_are_absolute_and_output_is_stable
test_pause_verb_override_renders_all_brief_scaffolds
test_ship_branch_defaults_to_loud_placeholder
test_ship_branch_flag_lands_verbatim
test_ship_branch_flag_rejected_outside_ship
test_co_author_prohibition_in_every_variant
test_scout_and_secondmate_load_decision_hold_policy
test_scout_and_secondmate_scaffold
