#!/usr/bin/env bash
# Drives gh-board against a stub gh that models just enough of GitHub: repos
# with issues and pull requests, and the two personal boards. Every gh call is
# logged so the test can prove which runs wrote and which only read.
set -euo pipefail

repo_root=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
gh_board=$repo_root/bin/gh-board
list_limit=$(sed -n 's/^list_limit=//p' "$gh_board")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

stubbin=$work/bin
fixtures=$work/github
log=$work/gh.log
mkdir -p "$stubbin"

command cat >"$stubbin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_LOG"
unexpected() {
  printf 'UNEXPECTED %s\n' "$*" >>"$GH_LOG"
  printf 'stub gh: unexpected call: %s\n' "$*" >&2
  exit 1
}
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
repo_file() { printf '%s/repos/%s.json' "$GH_FIXTURES" "$(lower "${1//\//_}")"; }

owner='' url='' repo='' state=open author='' assignee=''
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    --owner) owner=${args[i + 1]} ;;
    --url) url=${args[i + 1]} ;;
    --repo) repo=${args[i + 1]} ;;
    --state) state=${args[i + 1]} ;;
    --author) author=${args[i + 1]/@me/hattajr} ;;
    --assignee) assignee=${args[i + 1]/@me/hattajr} ;;
  esac
done

case "${1:-} ${2:-}" in
  'project item-list')
    # Only the personal account's boards exist; Wellysis' own project 5 is a
    # different board that must never be touched.
    [ "$owner" = hattajr ] || unexpected "$@"
    board="$GH_FIXTURES/project-$3.json"
    [ -r "$board" ] || { printf 'project not found\n' >&2; exit 1; }
    cat "$board"
    ;;
  'project item-add')
    [ "$owner" = hattajr ] || unexpected "$@"
    board="$GH_FIXTURES/project-$3.json"
    if grep -Fxq -- "$url" "$GH_FIXTURES/fail-add" 2>/dev/null; then
      printf 'GraphQL: Something went wrong while executing your query.\n' >&2
      exit 1
    fi
    jq --arg url "$url" '.items += [{content: {type: "Issue", url: $url}}] | .totalCount += 1' \
      "$board" >"$board.new"
    mv "$board.new" "$board"
    printf 'Added item\n'
    ;;
  'issue list')
    if grep -Fxiq -- "$repo" "$GH_FIXTURES/fail-list" 2>/dev/null; then
      printf 'HTTP 502: Bad Gateway\n' >&2
      exit 1
    fi
    file=$(repo_file "$repo")
    [ -r "$file" ] || { printf '[]\n'; exit 0; }
    # gh issue list never returns pull requests.
    jq --arg state "$state" --arg author "$author" --arg assignee "$assignee" '
      [ .[]
        | select(.kind == "issue")
        | select($state == "all" or .state == $state)
        | select($author == "" or .author == $author)
        | select($assignee == "" or (.assignees | index($assignee)))
        | {url} ]' "$file"
    ;;
  'api repos/'*)
    path=${2#repos/}
    number=${path##*/}
    file=$(repo_file "${path%/issues/*}")
    found=''
    [ ! -r "$file" ] || found=$(jq -c --arg n "$number" '
      .[] | select(.url | test("/(issues|pull)/" + $n + "$"))
      | {html_url: .url, pull_request: (if .kind == "pr" then {} else null end)}' "$file")
    if [ -z "$found" ]; then
      printf '{"message":"Not Found","status":"404"}'
      printf 'gh: Not Found (HTTP 404)\n' >&2
      exit 1
    fi
    printf '%s\n' "$found"
    ;;
  *) unexpected "$@" ;;
esac
STUB
chmod +x "$stubbin/gh"

reset_github() {
  rm -rf "$fixtures"
  mkdir -p "$fixtures/repos"
  : >"$log"
  command cat >"$fixtures/repos/hattajr_nix-config.json" <<'EOF'
[
  {"url": "https://github.com/hattajr/nix-config/issues/3", "kind": "issue", "state": "open", "author": "hattajr", "assignees": []},
  {"url": "https://github.com/hattajr/nix-config/issues/4", "kind": "issue", "state": "open", "author": "hattajr", "assignees": []},
  {"url": "https://github.com/hattajr/nix-config/issues/9", "kind": "issue", "state": "open", "author": "someone", "assignees": ["hattajr"]},
  {"url": "https://github.com/hattajr/nix-config/issues/10", "kind": "issue", "state": "open", "author": "someone", "assignees": []},
  {"url": "https://github.com/hattajr/nix-config/issues/11", "kind": "issue", "state": "closed", "author": "hattajr", "assignees": []},
  {"url": "https://github.com/hattajr/nix-config/pull/12", "kind": "pr", "state": "open", "author": "hattajr", "assignees": ["hattajr"]}
]
EOF
  command cat >"$fixtures/repos/hattajr_muslim-app.json" <<'EOF'
[
  {"url": "https://github.com/hattajr/muslim-app/issues/5", "kind": "issue", "state": "open", "author": "hattajr", "assignees": ["hattajr"]}
]
EOF
  command cat >"$fixtures/repos/wellysis_ai-dashboard.json" <<'EOF'
[
  {"url": "https://github.com/Wellysis/AI-dashboard/issues/7", "kind": "issue", "state": "open", "author": "someone", "assignees": ["hattajr"]}
]
EOF
  command cat >"$fixtures/repos/wellysis_beatlab.json" <<'EOF'
[
  {"url": "https://github.com/Wellysis/beatlab/issues/1", "kind": "issue", "state": "open", "author": "hattajr", "assignees": []}
]
EOF
  command cat >"$fixtures/repos/hattajr_secret-repo.json" <<'EOF'
[
  {"url": "https://github.com/hattajr/secret-repo/issues/1", "kind": "issue", "state": "open", "author": "hattajr", "assignees": []}
]
EOF
  command cat >"$fixtures/repos/someorg_beatlab.json" <<'EOF'
[
  {"url": "https://github.com/someorg/beatlab/issues/1", "kind": "issue", "state": "open", "author": "hattajr", "assignees": []}
]
EOF
  # A board can also hold pull requests and draft items, which have no URL.
  command cat >"$fixtures/project-4.json" <<'EOF'
{"items": [
  {"content": {"type": "Issue", "url": "https://github.com/hattajr/nix-config/issues/3"}},
  {"content": {"type": "PullRequest", "url": "https://github.com/hattajr/nix-config/pull/12"}},
  {"content": {"type": "DraftIssue", "title": "an idea"}}
], "totalCount": 3}
EOF
  command cat >"$fixtures/project-5.json" <<'EOF'
{"items": [
  {"content": {"type": "Issue", "url": "https://github.com/Wellysis/beatlab/issues/1"}}
], "totalCount": 1}
EOF
}

run_board() {
  env PATH="$stubbin:$PATH" GH_LOG="$log" GH_FIXTURES="$fixtures" "$gh_board" "$@"
}

fail() {
  printf 'gh-board test: %s\n' "$1" >&2
  exit 1
}

boards_digest() { cat "$fixtures"/project-*.json | cksum; }
adds_logged() { grep -c '^project item-add ' "$log" || true; }
assert_no_unexpected_calls() {
  ! grep -q '^UNEXPECTED' "$log" || fail "$1 made a call the stub does not model: $(grep '^UNEXPECTED' "$log")"
}

# --- add ----------------------------------------------------------------------

reset_github
status=0
output=$(run_board add https://github.com/Wellysis/AI-dashboard/issues/7 2>&1) || status=$?
[ "$status" = 0 ] || fail "add of an allowlisted issue failed: $output"
grep -Fxq 'project item-add 5 --owner hattajr --url https://github.com/Wellysis/AI-dashboard/issues/7' "$log" ||
  fail 'add did not put the Wellysis issue on the personal project 5'
jq -e '[.items[].content.url] | index("https://github.com/Wellysis/AI-dashboard/issues/7")' \
  "$fixtures/project-5.json" >/dev/null || fail 'the issue is not on board 5 after add'

# Adding it again, even spelled in another case, succeeds and writes nothing.
before=$(boards_digest)
for again in https://github.com/Wellysis/AI-dashboard/issues/7 https://github.com/wellysis/ai-dashboard/issues/7; do
  status=0
  output=$(run_board add "$again" 2>&1) || status=$?
  [ "$status" = 0 ] || fail "re-adding $again failed: $output"
  grep -Fq 'already on project 5' <<<"$output" || fail "re-adding $again did not say it was already there"
done
[ "$(adds_logged)" = 1 ] || fail 're-adding an issue called item-add again'
[ "$(boards_digest)" = "$before" ] || fail 're-adding an issue changed a board'

# Owner and repo names are case-insensitive on GitHub; the board gets the canonical URL.
run_board add https://github.com/HATTAJR/Nix-Config/issues/4 >/dev/null 2>&1 ||
  fail 'add rejected an allowlisted repo written in another case'
grep -Fxq 'project item-add 4 --owner hattajr --url https://github.com/hattajr/nix-config/issues/4' "$log" ||
  fail 'add did not put the hattajr issue on project 4 under its canonical URL'
assert_no_unexpected_calls add

# Anything outside the allowlist or owner mapping is refused with a reason.
reset_github
before=$(boards_digest)
while IFS='|' read -r url reason; do
  status=0
  err=$(run_board add "$url" 2>&1 >/dev/null) || status=$?
  [ "$status" != 0 ] || fail "add of $url exited zero"
  grep -Fiq -- "$reason" <<<"$err" || fail "add of $url did not explain '$reason' on stderr: $err"
done <<'EOF'
https://github.com/hattajr/secret-repo/issues/1|not on the allowlist
https://github.com/someorg/beatlab/issues/1|no board
https://github.com/hattajr/nix-config/pull/12|pull request
https://github.com/hattajr/nix-config/issues/12|pull request
https://github.com/hattajr/nix-config/issues/abc|not a GitHub issue URL
https://github.com/hattajr/nix-config/issues/3#issuecomment-1|not a GitHub issue URL
https://gitlab.com/hattajr/nix-config/issues/3|not a GitHub issue URL
hattajr/nix-config#3|not a GitHub issue URL
EOF
[ "$(adds_logged)" = 0 ] || fail 'a refused add still called item-add'
[ "$(boards_digest)" = "$before" ] || fail 'a refused add changed a board'
! grep -Eq 'secret-repo|someorg' "$log" || fail 'add asked GitHub about a repo outside the allowlist'

# A failed GitHub call names the issue it concerns.
status=0
err=$(run_board add https://github.com/hattajr/nix-config/issues/404 2>&1 >/dev/null) || status=$?
[ "$status" != 0 ] || fail 'add of a missing issue exited zero'
grep -Fq 'https://github.com/hattajr/nix-config/issues/404' <<<"$err" || fail "a failed lookup did not name the issue: $err"
printf 'https://github.com/hattajr/nix-config/issues/4\n' >"$fixtures/fail-add"
status=0
err=$(run_board add https://github.com/hattajr/nix-config/issues/4 2>&1 >/dev/null) || status=$?
[ "$status" != 0 ] || fail 'add exited zero when item-add failed'
grep -Fq 'https://github.com/hattajr/nix-config/issues/4' <<<"$err" || fail "a failed item-add did not name the issue: $err"
assert_no_unexpected_calls 'refused add'

adds_before=$(adds_logged)
for args in '' 'add' 'add https://github.com/hattajr/nix-config/issues/4 https://github.com/hattajr/nix-config/issues/9'; do
  status=0
  # shellcheck disable=SC2086 # the cases are whitespace-separated argument lists
  run_board $args >/dev/null 2>&1 || status=$?
  [ "$status" != 0 ] || fail "running with arguments '$args' exited zero"
done
[ "$(adds_logged)" = "$adds_before" ] || fail 'a usage error called item-add'

printf '%s\n' 'gh-board add test: PASSED (adds to mapped board, idempotent, case-insensitive, refusals, failure attribution)'

# --- sync ---------------------------------------------------------------------

expected_board_4='https://github.com/hattajr/muslim-app/issues/5
https://github.com/hattajr/nix-config/issues/4
https://github.com/hattajr/nix-config/issues/9'
expected_board_5='https://github.com/Wellysis/AI-dashboard/issues/7'

# Prints the URLs listed under one board's heading in dry-run output.
dry_run_group() {
  awk -v board="$1" '
    /^project [0-9]+/ { current = ($2 == board) ; next }
    current && NF { print $1 }' <<<"$2" | sort
}

reset_github
before=$(boards_digest)
status=0
output=$(run_board sync --dry-run 2>&1) || status=$?
[ "$status" = 0 ] || fail "sync --dry-run failed: $output"
[ "$(dry_run_group 4 "$output")" = "$expected_board_4" ] ||
  fail "dry-run listed the wrong issues for project 4: $output"
[ "$(dry_run_group 5 "$output")" = "$expected_board_5" ] ||
  fail "dry-run listed the wrong issues for project 5: $output"
[ "$(boards_digest)" = "$before" ] || fail 'dry-run changed a board'
! grep -Ev '^(project item-list|issue list) ' "$log" >/dev/null ||
  fail "dry-run made a call other than the two read-only listings: $(grep -Ev '^(project item-list|issue list) ' "$log")"

reset_github
status=0
output=$(run_board sync 2>&1) || status=$?
[ "$status" = 0 ] || fail "sync failed: $output"
added=$(sed -n 's/^project item-add \([0-9]*\) --owner hattajr --url \(.*\)$/\1 \2/p' "$log" | sort)
expected_adds=$(
  awk '{ print "4 " $0 }' <<<"$expected_board_4"
  awk '{ print "5 " $0 }' <<<"$expected_board_5"
)
[ "$added" = "$(sort <<<"$expected_adds")" ] || fail "sync added the wrong issues:
$added"
! grep -Eq 'secret-repo|someorg' "$log" || fail 'sync looked at a repo outside the allowlist'
! grep -q '^project item-add .*/pull/' "$log" || fail 'sync added a pull request'
assert_no_unexpected_calls sync

# Everything is on its board now, so a second sync writes nothing.
: >"$log"
run_board sync >/dev/null 2>&1 || fail 'a repeated sync failed'
[ "$(adds_logged)" = 0 ] || fail 'a repeated sync added issues that were already on their board'

# A failed add names its issue, the rest still go in, and the run fails.
reset_github
printf 'https://github.com/hattajr/nix-config/issues/4\n' >"$fixtures/fail-add"
status=0
err=$(run_board sync 2>&1 >/dev/null) || status=$?
[ "$status" != 0 ] || fail 'sync exited zero after a failed add'
grep -Fq 'https://github.com/hattajr/nix-config/issues/4' <<<"$err" || fail "sync did not name the failed issue: $err"
while read -r board url; do
  grep -Fxq "project item-add $board --owner hattajr --url $url" "$log" || fail "sync stopped before adding $url"
done <<'EOF'
4 https://github.com/hattajr/nix-config/issues/9
4 https://github.com/hattajr/muslim-app/issues/5
5 https://github.com/Wellysis/AI-dashboard/issues/7
EOF

# A repo that cannot be listed is named, and the other repos are still synced.
reset_github
printf 'hattajr/muslim-app\n' >"$fixtures/fail-list"
status=0
err=$(run_board sync 2>&1 >/dev/null) || status=$?
[ "$status" != 0 ] || fail 'sync exited zero after a failed listing'
grep -Fq 'hattajr/muslim-app' <<<"$err" || fail "sync did not name the repo it could not list: $err"
grep -Fxq 'project item-add 5 --owner hattajr --url https://github.com/Wellysis/AI-dashboard/issues/7' "$log" ||
  fail 'sync gave up on the other repos after a failed listing'

# A board too big to list in full is refused rather than trusted partially.
reset_github
jq -n --argjson n "$list_limit" \
  '{items: [range($n) | {content: {type: "Issue", url: "https://github.com/hattajr/nix-config/issues/\(. + 1000)"}}], totalCount: $n}' \
  >"$fixtures/project-4.json"
status=0
err=$(run_board sync --dry-run 2>&1 >/dev/null) || status=$?
[ "$status" != 0 ] || fail 'sync trusted a board listing that reached the limit'
grep -Fq 'project 4' <<<"$err" || fail "a truncated board listing was not reported: $err"

status=0
run_board sync --force >/dev/null 2>&1 || status=$?
[ "$status" != 0 ] || fail 'sync accepted an unknown option'

printf '%s\n' 'gh-board sync test: PASSED (adds missing issues, skips present ones and PRs, dry-run grouped and read-only, failures named, partial listings refused)'
