# Contributing to OCP Lab

Thanks for your interest in contributing! This guide walks you through the process step by step.

## Prerequisites

- A [GitHub](https://github.com) account with access to this repo
- Git installed (`dnf install git` or `apt install git`)
- SSH key added to your GitHub account ([docs](https://docs.github.com/en/authentication/connecting-to-github-with-ssh))

## Workflow

```
Issue → Clone → Branch → Fix → Commit → Push → PR → Review → Merge
```

1. **Open an issue** — Describe what you want to change and why
2. **Clone the repo** — `git clone git@github.com:Ultimate-etamitlU/labs.git`
3. **Create a branch** — `git checkout -b fix/short-description`
4. **Make your change** — Edit the file(s)
5. **Commit with sign-off** — `git commit -s -m "fix: description"`
6. **Push your branch** — `git push origin fix/short-description`
7. **Open a Pull Request** — Link it to your issue with `Closes #N`
8. **Review** — A maintainer reviews and merges

Never push directly to `main`. Always work on a feature branch.

## Example: Fixing a Typo

Let's say you found a typo in `README.md` — the word "deploymnet" should be "deployment".

### Step 1: Open an Issue

Go to [Issues](https://github.com/Ultimate-etamitlU/labs/issues) and create a new issue:

> **Title:** Fix typo in README.md
>
> **Description:** "deploymnet" should be "deployment" in the Quick Start section.

Note the issue number (e.g., `#42`).

### Step 2: Clone the Repo

```bash
# First time only — clone the repo:
git clone git@github.com:Ultimate-etamitlU/labs.git
cd labs

# If you already have it cloned, just pull latest:
cd labs
git checkout main
git pull origin main
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

Go to the [repo on GitHub](https://github.com/Ultimate-etamitlU/labs). You'll see a banner saying your branch was recently pushed — click **"Compare & pull request"**.

The PR template will auto-fill. Fill in:
- **Summary** — What you changed and why
- **Related issue** — `Closes #42`

That's it! A maintainer will review and merge your PR.

> **Tip:** You can also create a PR from the command line:
> ```bash
> gh pr create --title "fix: correct typo in README.md" --body "Closes #42"
> ```

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
