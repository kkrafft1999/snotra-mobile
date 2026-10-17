# Git workflow: branch, pull request and squash merge

Taken over from the Snotra repository on 2026-10-17
([`git-workflow.md`](https://github.com/kkrafft1999/snotra/blob/main/.claude/rules/git-workflow.md))
and adapted to a repository that has no code and no pipeline yet.

A finished task is carried through to a merged pull request without the user
triggering each step. `main` carries one commit per pull request.

## The gate, now and later

- **Now:** there is no Xcode project, no test and no CI. `main` has **no
  ruleset** yet. The rule still
  holds without the machine behind it: every change goes through a pull
  request, nothing is pushed to `main` directly.
- **As soon as the Xcode project exists:** a workflow under `.github/workflows/`
  runs the tests on macOS, and a ruleset on `main` makes that check required,
  forbids force-pushing and deleting the branch, with no bypass actors — as in
  Snotra. Setting up the ruleset changes the repository's protection, so the
  user decides it (see *Ask first*).

## Without asking

1. **One branch per task**, cut from an up-to-date `main`, named after what it
   does (`feature/qr-pairing`, `fix/keychain-access-group`, `docs/relay-budget`).
2. **Commit in readable steps** as the work goes, in English, imperative mood,
   one concern per commit (see [`language.md`](./language.md)).
3. **Push and open the pull request as soon as the task is done** and, once
   tests exist, they ran green locally (`xcodebuild test` against an iPhone
   simulator). The pull request carries `Closes #N` for the matching issue (see
   [`task-management.md`](./task-management.md)) — in English, a German
   "Schließt #N" closes nothing. Title and body are English.
4. **Squash-merge** once the checks below pass, with the pull request number in
   the title. GitHub deletes the head branch on merge (*Automatically delete
   head branches*, `delete_branch_on_merge`, on since 2026-10-17) — check that
   it is gone, don't delete it by hand, and never before the merge: a pull
   request whose head branch disappears is closed unmerged. Then tidy up the
   local branch and bring `main` in the main checkout up to date with
   `git pull --ff-only`.

The user is told afterwards, in one sentence, what happened: pull request
number, merge, deleted branch.

## What is checked before merging

- **All required checks green** — once there are any. Not skipped, not still
  running. "It's running" is not a result.
- **No conflicts with `main`** (`mergeable: MERGEABLE`, status `CLEAN`).
- **No open reviews or comments** that call for an answer — including from bots,
  when they carry a real objection.
- **The diff contains nothing beyond the task** — no foreign changes from a
  parallel session, no credentials or keys (no `GoogleService-Info.plist` with
  real values, no signing material), nothing touching `.github/` unless the task
  is about it.

If one of these fails, don't merge — report it.

## Ask first

- **Tests red locally**, or not run although they exist — then nothing gets
  pushed either.
- **Conflicts, force-push, rebase** — anything that rewrites history.
- **The protection of `main`**: creating or changing the ruleset, switching
  repository settings.
- **Writing to `main` directly:** never, not even for a one-line fix.

When in doubt, the doubt wins: report the state and ask, rather than undo a
merge.

## Worktrees

Work happens in the **main checkout** (`~/Projects/snotra-mobile`), on the
task's branch — that is the folder the user sees in the Finder and opens in
Xcode. Files that only exist in a worktree under `.claude/worktrees/` are
invisible there.

A worktree is used **only when the user asks for it explicitly**, typically to
run tasks in parallel sessions (user decision, 2026-10-17). A session that the
app started in a worktree anyway says so at the start, moves the work into the
main checkout (detach the branch in the worktree, `git switch <branch>` in the
main checkout) and carries on there.

When a session ran in a worktree, its result still ends up on `main` the normal
way — pull request, squash merge — and the main checkout is updated with
`git pull --ff-only` afterwards.

Cleaning up a worktree once its pull request is merged:

1. **Merge confirmed** — `gh pr view <nr> --json state,headRefOid` says
   `MERGED`, and `headRefOid` equals the local branch tip
   (`git rev-parse <branch>`). A squash merge leaves the branch unmerged in
   git's eyes, so `git branch -d` refuses; this check is what makes
   `git branch -D` safe. Different SHAs mean local commits that never reached
   the pull request — stop and ask.
2. **Nothing unique left in the worktree** — `git -C <worktree> status
   --porcelain` must be empty, and gitignored build output worth keeping is
   named to the user first. Anything found: leave that worktree in place.
3. **Remove** — `git worktree remove <worktree>`, `git branch -D <branch>`, then
   `git worktree prune` and `git fetch --prune` in the main checkout.

## Order

Issue → branch → commits → local tests → push → pull request with `Closes #N` →
checks → the review above → squash merge → branch deleted → `main` pulled →
one sentence to the user.
