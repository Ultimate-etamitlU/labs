# Contributing to OCP Lab

Thanks for your interest in contributing! This guide walks you through the process step by step.

## Prerequisites

- A [GitHub](https://github.com) account
- Git installed (`dnf install git` or `apt install git`)
- SSH key added to your GitHub account ([docs](https://docs.github.com/en/authentication/connecting-to-github-with-ssh))

## Workflow

1. **Open an issue first** — Describe what you want to change and why
2. **Fork the repo** — Click "Fork" on the [repo page](https://github.com/Ultimate-etamitlU/labs)
3. **Clone, branch, fix, push** — See the example below
4. **Open a Pull Request** — Link it to your issue

Never push directly to `main`.

## Example: Fixing a Typo

Let's say you found a typo in `README.md` — the word "deploymnet" should be "deployment".

### Step 1: Open an Issue

Go to [Issues](https://github.com/Ultimate-etamitlU/labs/issues) and create a new issue:

> **Title:** Fix typo in README.md
>
> **Description:** "deploymnet" should be "deployment" in the Quick Start section.

Note the issue number (e.g., `#42`).

### Step 2: Fork and Clone

```bash
# Fork the repo on GitHub (click the "Fork" button), then clone YOUR fork:
git clone git@github.com:<your-username>/labs.git
cd labs
```

### Step 3: Create a Branch

```bash
git checkout -b fix/readme-typo
```

Use a descriptive branch name. Prefixes like `fix/`, `feat/`, `docs/` help.

### Step 4: Make Your Change

Edit the file and fix the typo:

```bash
vi README.md
# fix "deploymnet" → "deployment"
```

### Step 5: Commit

```bash
git add README.md
git commit -s -m "fix: correct typo in README.md

Fixes #42"
```

The `-s` flag adds your `Signed-off-by` line, which is **required** for all commits.

### Step 6: Push

```bash
git push origin fix/readme-typo
```

### Step 7: Open a Pull Request

Go to your fork on GitHub. You'll see a banner to create a Pull Request. Click it.

The PR template will auto-fill. Fill in:
- **Summary** — What you changed and why
- **Related issue** — `Closes #42`

That's it! A maintainer will review and merge your PR.

## Commit Conventions

- Add `Signed-off-by` to every commit (use `git commit -s`)
- Subject line: imperative mood, max 50 chars (e.g., "fix: correct DNS zone serial")
- Reference the issue in the commit body (`Fixes #N` or `Closes #N`)

## Good First Contributions

Not sure where to start? Here are some ideas:

- Fix typos or unclear wording in docs
- Improve error messages in scripts
- Add missing comments or usage examples
- Report bugs you encounter on the lab system
- Suggest improvements via issues

## Questions?

Open an issue or reach out on Slack. We're happy to help first-time contributors.
