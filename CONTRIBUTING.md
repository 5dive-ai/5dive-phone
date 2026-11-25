# Contributing

Bug reports and fixes are welcome.

## Report a bug

Open an issue with:

- what you ran (`5dive phone …`) and the full output, including the exit code
- the app, the phone model and its Android version
- the plugin version (`phone/.claude-plugin/plugin.json`)

Never paste a pairing code, a screenshot with your messages or account on it, or your
`actions.jsonl`.

## Make a change

1. Fork, branch from `main`, keep the change to one thing.
2. Run the suite. It is plain bash with a fake adb, so it needs no phone and no server:

   ```sh
   bash tests/phone_unit.sh
   ```

   CI runs it on every pull request.
3. A change in behaviour gets a test that fails without it, and an entry under `## Unreleased` in
   `CHANGES.md` that says what a user sees now.
4. Open the pull request against `main` and say what you ran.

`5dive-ai/5dive-plugins` carries a byte-for-byte copy of `phone/`. A change lands here first; that
copy is then re-synced from this repo, never edited by hand.

## Rules the code keeps

- Nothing is installed on the phone. It is driven with what Android ships (adb, uiautomator,
  `input`).
- A tap that pays, sends, posts or deletes is checked against the owner's policy before any step
  runs, and a step must never be relabelled to get past an ask.
- A grant fits the exact steps the owner approved, on that phone, once.
- Screenshots and the action log stay private to the agent's account on the server.

A pull request that weakens one of these will not be merged.

## License

By contributing you agree your work is licensed under Apache 2.0, the same as the rest of the repo
(see `LICENSE`).
