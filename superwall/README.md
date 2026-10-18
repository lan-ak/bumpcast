# Your paywalls

Each directory under `paywalls/` is one paywall — React pages in `app/`,
products and name in `config.ts`.

```bash
bun dev      # open the studio and preview live
bun run push # push versions to Superwall (production untouched)
bun run ship # push and promote to production
```

## For coding agents

The `superwall-framework` skill is the playbook for this directory: the
layout and inset system, mobile design, the CLI, and where the docs are.
`superwall login` installs it; otherwise:

```bash
npx skills add https://github.com/superwall/skills/tree/next --skill superwall-framework --global --yes --agent claude-code universal --full-depth
```

The framework is on the `next` channel: its commands exist only while
`SUPERWALL_CHANNEL=next` is set in the environment.

Docs: `curl -sL https://superwall.com/docs/framework/llms.txt`
