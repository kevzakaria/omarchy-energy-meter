<!--
Base this PR on `release`, not `main`.

GitHub offers `main` by default because Omarchy's installer requires it to be
the repository default: `omarchy plugin add` clones the default branch and
`omarchy plugin update` fast-forwards to it, and neither can be pointed at a
tag. So anything that lands on `main` is live for every installed copy on their
next update. `main` moves only when a version is cut.

Use the "base" dropdown above to switch to `release`.
-->

## What and why

<!-- The change, and the problem it solves. Why, not only what. -->

## Tested on

- CPU / GPU:
- Desktop or laptop:
- <!-- If it touches sensor selection or the maths, say what you measured and
      against what. A number without a reference is not evidence. -->

## Checklist

- [ ] Base branch is `release`
- [ ] `omarchy plugin validate .` passes
- [ ] `python3 -m py_compile bin/omaenergy` passes
- [ ] Ran `omarchy restart shell` and checked the shell log for QML errors
      attributable to this plugin
- [ ] Changelog entry added to the README under `Unreleased`, if a user can see
      the change: a new setting, a renamed JSON field, or a number that moves
- [ ] No estimate is presented with a label that implies measurement
- [ ] No new runtime dependency (backend is Python 3 stdlib only)
