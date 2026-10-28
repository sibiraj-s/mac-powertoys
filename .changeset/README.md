# Changesets

Each user-facing change gets a changeset: a small Markdown file that says how it
bumps the version and what to put in the changelog.

```sh
npx changeset          # pick patch / minor / major and write a summary
```

Commit the file with the change. On `master`, the Release workflow keeps a
"Release powertoys@<version>" pull request open that bumps `package.json` and updates
`CHANGELOG.md`. Merging it builds, signs and notarizes the DMG with
`scripts/build.sh`; only once that passes does `changeset publish` tag `v<version>`
and create the GitHub Release, with the DMG attached.
