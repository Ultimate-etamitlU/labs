---
name: labportal-workflow
description: "Work on the OCP lab portal and deploy portal changes to BigB for runtime testing. Use when changing portal code or infrastructure that must be synced to the shared lab host."
---

# Lab Portal Workflow

Treat the local `labs` checkout as the source of truth. Read `CLAUDE.md` and check the current branch and worktree before making changes.

## BigB workflow

- Make and review code changes locally. BigB has no GitHub SSH key; never run `git fetch`, `pull`, or `push` there.
- When runtime testing on BigB is requested, initiate SSH from the local machine and sync only the required files with `scp`, `rsync`, or a tar stream. Preserve and inspect any existing BigB worktree modifications and staging/backup files before overwriting paths; never reset or clean the server worktree.
- Test the synced revision on BigB, then commit and push from the local checkout. Report what was synced, what was verified on BigB, and the pushed commit.
- Before restarting the portal or reloading shared infrastructure, check for active deployments and running clusters. Never destroy VMs as part of portal work.

Follow the repository's `CLAUDE.md` for shared-lab constraints and component-specific procedures.
