# Contributing to Relaycat

Thanks for helping. Relaycat is a small native Mac app with no dependencies, so getting set up takes a minute.

## Build and run

You need macOS 14 or later and the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/krutikJain/relaycat.git
cd relaycat
./build.sh --install        # builds a universal app and copies it to /Applications
```

Try the app with sample profiles, without touching your real ones:

```bash
open build/Relaycat.app --args --demo
```

The app icon and Mochi are drawn in code, in `Sources/Mochi.swift`. The top of `build.sh` shows how to redraw the icon after changing them.

## Checking your change

There's no test target yet, so please check by hand, and say what you checked in the pull request.

- Try it in demo mode first.
- Don't try changes that write files (switch, restore, rename, delete) on your real profiles until you have a backup of them.
- Look at the window at its smallest size and at a large size, in light and dark.

## Ground rules

- **Never write to Claude's data without a backup**, and send things to the Trash rather than deleting them.
- **Never use a refresh token.** Live limits read the access token only.
- **No new dependencies** without a good reason. The app builds with `swiftc` alone.
- **Keep the copy plain.** Sentence case, short sentences, no exclamation marks.
- One feature or fix per pull request.

## Reporting security issues

Please don't open a public issue. Use **Report a vulnerability** on the repository's Security tab so it reaches the maintainers privately.
