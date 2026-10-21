# Chess Mortem

Chess Mortem is a free chess analyzer for your games. Share a game from any
app and get analysis in plain English, run locally on your device.

## What you get

- **Coach line**: one line per move on what happened: the tactic you fell
  for, the piece you left hanging, the win you missed, or the brilliant move you
  found.
- **Stockfish analysis**: Stockfish analyzes every move at the depth you pick,
  from 10 to 22, and the app rates it: Brilliant, Great, Best, Excellent, Good,
  Inaccuracy, Mistake, Miss or Blunder. Stockfish 16 is bundled in the app.
  Stockfish 18 is an optional download for stronger analysis.
- **Better moves**: on every mistake, blunder or miss, see the move you should
  have played, why, and its line.
- **What if**: try any move in any position and see whether it would have
  worked.
- **Accuracy**: both players' scores for the whole game and for the opening,
  middlegame and endgame, and a graph of who was winning when.
- **Openings**: named from a built-in book.
- **Longer explanations (optional)**: besides the coach line, ask an AI
  provider to explain any move. It needs a free key from Groq,
  Google Gemini, OpenRouter or NVIDIA NIM (no card needed).
- **Share**: share your games with every move's verdict on them.
- **Your board**: several board themes and piece sets to customize.

It's free and open source (GPL), with no ads and no daily limit. Your games
stay on your phone, there's no account, and analysis works offline. Nothing is
uploaded, except when you ask for a longer explanation: that request goes to
the AI provider you chose.

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

## Privacy

The app collects nothing. See [PRIVACY.md](PRIVACY.md).

## Licence

Copyright © 2026 Apurba Saha

Chess Mortem is free software under the GNU General Public License, version 3
or later (see [LICENSE](LICENSE)). It is built on the
[Stockfish](https://github.com/official-stockfish/Stockfish) engine, also GPL-3.0.
