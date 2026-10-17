# Project language: English inside, bilingual towards the user

Taken over from the Snotra repository on 2026-10-17
([`language.md`](https://github.com/kkrafft1999/snotra/blob/main/.claude/rules/language.md)).

The conversation stays German — answers, explanations and questions back to the
user. **What the agent writes into the repository or into an issue is
English.** Translating is part of the job, not something to ask about first.

## English — everything the project says to itself

- **GitHub issues and pull requests** — title, body, comments.
- **Commit messages**, including the squashed ones on `main`.
- **`docs/`** — the concept and the labels inside its diagrams.
- **`.claude/`** — rules and skills. German trigger phrases in a skill's
  `description` stay, with English ones next to them.
- **Code** — identifiers, comments, log output, developer-only error messages,
  test names.

## Bilingual — everything the user meets

**English is the source, German is derived from it**, to the same standard. A
German version that lags behind is a defect.

- **The app's UI** — every string the user sees goes through a String Catalog
  (`Localizable.xcstrings`) with `en` as the development language and `de`
  complete next to it, and the App Store texts likewise.
- **`README.md`** describes the app from the user's side and counts as
  user-facing; its German counterpart is `README.de.md`. Everything under
  `docs/` does not.

German texts address the reader as **du**, never **Sie**.

## What this rule does not say

- **It does not change the chat.**
- **It does not rewrite history** — existing commits and issues stay as they are.
- **It is not word-for-word translation.**
- **It does not touch quoted material** — a user's own words, a third-party
  error message, a tool's output stay as they are.
