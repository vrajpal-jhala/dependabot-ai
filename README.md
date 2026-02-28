# Dependabot with AI

Automated dependency update pipeline for GitLab projects using Node.js/npm. On a schedule, it checks for outdated npm packages, applies updates, and opens a Merge Request - optionally enriched with AI-generated changelog analysis.

---

## Prerequisites

- **GitLab.com** - hardcoded to `https://gitlab.com`; self-hosted instances require a code change
- **npm/yarn projects** - no support for other ecosystems (pip, bundler, etc.)
- **`package.json` / `package-lock.json`** - yarn and pnpm lockfiles are not handled
- **SSH remote required** - MR creation uses `git push -o merge_request.create`; HTTPS remotes won't work
- **AI via OpenRouter** - uses [openrouter.ai](https://openrouter.ai); not a direct OpenAI/Anthropic integration
- **`dependabot-omnibus` pinned to `0.330.0`** - won't self-update; bump manually when needed
- **Ruby 3.3 runtime** - older Ruby versions are untested

---

## How it works

1. **`dependabot_with_ai.rb`** - Ruby script that:
   - Parses `package.json` / `package-lock.json` using the Dependabot core library
   - Checks each top-level dependency for updates, respecting per-package strategies (patch/minor/major/ignore) configured in `.dependabotrc.mjs`
   - Applies updates one-by-one, accumulating successful ones and skipping conflicts
   - Optionally fetches changelogs (remote via GitHub, fallback to `node_modules`) and sends them to an AI model via OpenRouter for a risk/breaking-change summary
   - Creates a branch and opens a GitLab MR via `git push -o merge_request.create`

2. **`.gitlab-ci.yml`** - Single `dependency_update` job that:
   - Installs Node.js and the `dependabot-omnibus` gem
   - Sets up SSH for pushing branches back to the repo
   - Runs the script above
   - Cleans up the SSH key after

---

## Required CI variables

| Variable | Purpose |
|---|---|
| `SSH_PRIVATE_KEY` | Deploy key with write access to push branches |
| `DEPENDABOT_EMAIL` | Git author email for commits |
| `TARGET_BRANCH` | Branch to target for MRs (e.g. `dev`) |
| `OPENROUTER_API_KEY` | *(optional)* Enables AI changelog analysis |
| `AI_ANALYSIS_MODEL` | *(optional)* Model slug, e.g. `anthropic/claude-sonnet-4` |
| `GITHUB_TOKEN` | *(optional)* Raises GitHub API rate limit for changelog fetching (60 → 5000 req/hour) |
| `MR_ASSIGNEE_USERNAME` | *(optional)* GitLab username to assign MRs to |

---

## Configuration

Place a `.dependabotrc.mjs` in the repo root to control update strategies:

```js
export default {
  settings: {
    target_branch: "dev",
    update_strategy: "minor_and_patch", // patch_only | minor_and_patch | all
    ai_analysis: { enabled: true, model: "anthropic/claude-sonnet-4" }
  },
  dependencies: {
    ignore: ["eslint"],
    patch_only: ["react", "react-dom"],
    minor_updates: ["axios"],
    major_updates: ["@types/*"]
  },
  dev_dependencies: { update_strategy: "all" }
}
```

If absent, sensible defaults apply.

---

## Triggering

The job runs on schedule when `$DEPENDABOT_UPDATE == "true"` and `$CI_PIPELINE_SOURCE == "schedule"`. Set that up under **CI/CD → Schedules** in GitLab.
