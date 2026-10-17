# Task management

Taken over from the Snotra repository on 2026-10-17
([`task-management.md`](https://github.com/kkrafft1999/snotra/blob/main/.claude/rules/task-management.md)).
Everything runs through GitHub issues.

## Where a task goes

The mobile remote spans three repositories. A task is filed where its change
will land:

| The change is in … | Issue in |
| --- | --- |
| The iPhone app | **this repository**, https://github.com/kkrafft1999/snotra-mobile/issues |
| The protocol, its test vectors, the desktop's remote bridge, the reference client | [Snotra](https://github.com/kkrafft1999/snotra/issues) |
| The relay (Functions, Realtime Database, rules), the privacy notice on the website | [snotra-promotion](https://github.com/kkrafft1999/snotra-promotion/issues) |

The epic that holds it together is
[snotra#1081](https://github.com/kkrafft1999/snotra/issues/1081); app issues
link to it.

- **Progress** is tracked on the **GitHub project "Snotra AI"** (number 2,
  kanban board: Backlog → Ready → In progress → In review → Done) —
  https://github.com/users/kkrafft1999/projects/2. It is a user project, so it
  takes issues from this repository too.
- Issues are created **directly with `gh issue create`**. New issues do not land
  on the board by themselves: add them and set the column to `Backlog` (never
  `Ready` — what comes next is the user's call):
  ```sh
  gh project item-add 2 --owner kkrafft1999 --url <issue-url>
  gh project item-edit --id <item-id from item-add> \
    --project-id PVT_kwHOAQKGm84BjXUk \
    --field-id PVTSSF_lAHOAQKGm84BjXUkzhiL4mY \
    --single-select-option-id f75ad846   # = Backlog
  ```
- If `gh` cannot write for once: print the finished issue text **in the
  conversation** and ask the user to create it. Don't write it into the
  repository.
- **No** external tool and **no** task lists in the repository. The current
  state of the app is described in `README.md` and in `docs/`, not in a status
  list.

## What to do when asked "What's next?", "Where do we stand?", "Backlog?"

1. **Query the board, open issues only** — never drop the `--query`; without it
   the oldest, mostly closed items fill the limit:
   ```sh
   gh project item-list 2 --owner kkrafft1999 --query "is:issue is:open" \
     --limit 200 --format json
   ```
   Keep the items of this repository and those of the epic
   [snotra#1081](https://github.com/kkrafft1999/snotra/issues/1081) in the
   other two — the app depends on them (concept §9).
2. **Then the flat list** — `gh issue list --repo kkrafft1999/snotra-mobile
   --state open` — for issues that never made it onto the board.
3. Read individual issues where needed to judge dependencies.
4. **Check the working tree** (`git status`, `git worktree list`) — started work
   is part of the answer.
5. Summarise and recommend an order — Ready first, the backlog behind it. If
   there are no open issues, say so instead of inventing something.
6. **Never hand over bare issue numbers.** Every candidate comes with its title
   and one sentence on what it is about and what it would take.

## New tasks and ideas from the conversation

- When the user names a **concrete task, a bug or an idea**: write the issue
  with the sections that have proven useful — current state with the date it
  was checked, cross-references, definition of done — **in English, even when
  it was dictated in German**, and create it **right away**
  (`--label enhancement` or `--label bug`). Put the body file in the
  scratchpad, not in the repository. Mention the issue link afterwards.
- **Larger topics** get an issue as well, written out far enough to be split up
  later.
