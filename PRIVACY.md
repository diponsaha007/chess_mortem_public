# Chess Mortem privacy policy

Last updated: 21 October 2026

Chess Mortem is a chess analysis app. It is developed by one person and
published as free software under the GNU General Public License, version 3 or
later. This page covers the Android app.

## What the developer collects

Nothing. The app has no account, no analytics, no advertising and no crash
reporting service. The developer never receives your games, your settings or
anything about how you use the app.

## What stays on your device

- The games you paste or share into the app, and their analysis.
- Your settings, including the player name you enter so the app knows which
  side you played.
- API keys you add for longer explanations. These are kept in the device's
  encrypted storage.
- The app's log, which helps you see why something failed. It is held in
  memory only and is gone when the app closes.

Uninstalling the app deletes all of this. If your device backs up app data to
your Google account, Android may include the app's games and settings in that
backup, as it does for other apps; you control this in your device settings.

## What is sent, and when

**Longer explanations.** Explanations are optional and need an API key of your
own, from an AI provider you choose (Groq, Google Gemini, OpenRouter or
NVIDIA NIM). When you tap "Explain more" on a move, the app sends
that provider the chess position, the moves around it, and the engine's
assessment, using your key. Player names are not sent. The provider handles
that request under its own privacy policy and terms. Nothing is sent to any
provider unless you tap the button.

**The stronger engine.** If you choose the newer engine in Settings, the app
downloads its data files (about 80 MB) once, from the Stockfish project's
server. That server sees an ordinary download request, like any website does.

Nothing else is sent anywhere. Analysis runs entirely on your device.

## Children

The app collects no information from anyone, children included.

## Changes

If this policy changes, the new version will be published at this same
address with a new date at the top.

## Contact

Questions about this policy can be raised as an issue on the app's source code
repository: https://github.com/diponsaha007/chess_mortem_public/issues
