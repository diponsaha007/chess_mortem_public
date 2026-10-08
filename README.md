# Chess Mortem

A free chess coach for your games: every move explained in plain English.

Paste a game or share a PGN into the app. Stockfish checks every move, gives it
a verdict from Brilliant to Blunder, and a coach line under the board says what
happened: "You allowed your opponent to fork the rook on a8".

## Why Chess Mortem

- **Free, with no daily limit.** Review every game you play. No subscription,
  no ads, no "come back tomorrow".
- **Your games stay on your phone.** Stockfish runs on the device, and each
  move's coach line is written by the app from the board itself, so analysis
  works offline. There is no account, and nothing is uploaded unless you ask
  for an AI explanation.
- **Ask "what if?"** Play any move on any position. It becomes a variation, gets
  evaluated and moves the eval bar.
- **AI explanations, if you want them.** Get a free API key from Groq, Google
  Gemini, OpenRouter or NVIDIA NIM (no card needed), add it in Settings, and
  "Explain more" turns any coach line into a short paragraph. Each free key
  has a rate limit; add keys from several providers and switch when one runs
  out.
- **Open source.** The full source of every release is public under the GPL.

## What you get

- Verdicts: Brilliant, Great, Best, Excellent, Good, Inaccuracy, Mistake, Miss,
  Blunder.
- The engine's better line for every mistake, to step through on the board.
- Skip buttons that jump straight to the moves that decided the game.
- A summary with winning chances over the game, accuracy per player and per
  phase, and a count of each verdict.
- Openings named from a built-in book.

## Building

```bash
flutter pub get
flutter run --release
```

A release build has no Logs screen. To include it,

```bash
flutter run --release --dart-define=SHOW_LOGS=true
```

Debug builds (`flutter run`) always have it.

Written explanations need an API key, added in Settings; none is stored in
the repo.

## Privacy

The app collects nothing. See [PRIVACY.md](PRIVACY.md).

## Licence

Copyright © 2026 Apurba Saha

Chess Mortem is free software under the GNU General Public License, version 3
or later (see [LICENSE](LICENSE)). It is built on the
[Stockfish](https://github.com/official-stockfish/Stockfish) engine, also GPL-3.0.
