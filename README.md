# ocx-lan-filter · LAN Model Proxy

**English** · [Русский](README.ru.md)

Share **one chosen model** from your local [OpenCodex (`ocx`)](https://github.com/lidge-jun/opencodex) with other devices
on your home network, behind an access key, without exposing the rest of `ocx`.
A small menu bar app for macOS lets you manage it without touching the terminal.

```
other device ──HTTP──▶ <MAC_LAN_IP>:10200 (ocx-lan-filter) ──▶ 127.0.0.1:10100 (ocx) ──▶ provider
                       key check, alias, path allow-list        loopback only
```

`ocx` keeps listening on `127.0.0.1` only. You do not have to switch it to `0.0.0.0`, so local tools (codex, opencode, omp)
keep working without a token.

## Why a separate proxy

- `ocx` access keys (`ocx access key create`) **cannot restrict models**: any key sees the whole catalog.
- With `hostname: 0.0.0.0` `ocx` demands a token from every client, local ones included.
- The filter fixes both: only the filter faces the network, and it lets exactly the aliases you define through.

## Features

- Several **endpoints**, each with its own port, access scope (whole LAN or this Mac only), key, and set of **aliases**
  (alias → real `ocx` model). Clients only ever ask for the alias; you can change the model behind it at any time.
- Switching a model applies **instantly**, with no restart and no client reconfiguration.
- Strict allow-list: `GET /v1/models`, `GET /healthz`, `POST /v1/chat/completions`, `POST /v1/responses`. Everything else is 404;
  any model other than a configured alias is 403; a missing or wrong key is 401.
- Streaming works. Standard library only, no Python dependencies.
- Native **menu bar app** (SwiftUI, Apple Liquid Glass look on macOS 26, material fallback on macOS 14–15) and a `lanmodel` CLI.
- Closing the app does **not** stop the proxy: it runs as a `launchd` agent.
- The app UI is available in **English and Russian**. It follows the system language (Russian only if it is your primary macOS language, English otherwise); you can override it in **Settings**.

## Requirements

- macOS 14 or newer (the Liquid Glass look needs macOS 26).
- Python 3 (`python3` from python.org, Homebrew, or Xcode Command Line Tools).
- A running [OpenCodex](https://github.com/lidge-jun/opencodex) on `127.0.0.1:10100` (the default).

## Install

### Option A: the app (recommended)

1. Download `LAN-Model-Proxy-<version>.dmg` from the [latest release](../../releases/latest).
2. Open the DMG and drag **LAN Model Proxy** into **Applications**.
3. The app is ad-hoc signed and not notarized, so macOS blocks the first launch. Do one of:
   - open **System Settings → Privacy & Security**, scroll down and click **Open Anyway** for LAN Model Proxy; or
   - run `xattr -dr com.apple.quarantine "/Applications/LAN Model Proxy.app"` once.
4. Launch it. A network icon appears in the menu bar. Click it.
5. If the window shows **“Service not installed”**, click **Install**. This copies the filter to
   `~/.local/share/ocx-lan-filter/`, generates an access key, creates a default config and registers the `launchd` service.
   The default model is the first one `ocx` currently serves; change it right away (see below).

### Option B: from source

```sh
git clone https://github.com/IMPOSTOR15/ocx-lan-filter.git
cd ocx-lan-filter
./install.sh                           # service + lanmodel CLI (~/.local/bin)
cd menubar
swift test                             # optional
./scripts/build_app.sh                 # builds menubar/build/LAN Model Proxy.app
./scripts/install_app.sh               # copies it to ~/Applications and launches it
./scripts/make_dmg.sh                  # optional: universal build packed into a DMG
```

`install.sh` is idempotent. It never overwrites an existing key or config, so it is safe to re-run after updating.
Make sure `~/.local/bin` is in your `PATH` if you want to use `lanmodel`.

## Using the app

Everything lives in one window under the menu bar icon (no separate windows or dialogs).

- **Endpoint list.** One card per endpoint: status, URL, and each alias with the model behind it. Click the model pill to pick another
  model from the `ocx` catalog (with search). The change is applied right away.
- **Card buttons.** Copy URL, copy a ready-made `curl`, copy the key (cleared from the clipboard after 60 s), run a real
  test request through the endpoint, **Edit**.
- **Endpoint form (＋ or Edit).** Name, enabled switch, access (**whole network** `0.0.0.0` / **this Mac** `127.0.0.1`), port,
  access key (show for 15 s, copy, rotate), aliases with their context length, delete.
- **Footer.** Settings, restart the service, open the log, quit.
- **Settings.** Language (System / Русский / English; the choice is applied instantly), launch at login, app version.
- A banner appears when the service is missing, outdated or stopped, when the config is invalid, or when a model is no longer in the `ocx` catalog.
  Where possible it has a one-click fix.

The key is never written to logs or shown in the UI unless you explicitly press **Show**.

## Using the CLI

```sh
lanmodel            # current alias → model
lanmodel list       # numbered models that ocx serves
lanmodel set 6      # switch by number…
lanmodel set <id>   # …or by exact id
lanmodel test       # real request through the filter
lanmodel restart    # restart the service (only needed after editing filter.py)
```

## Connecting a client

Take the URL and key from the app (copy buttons) or from the files below. Any OpenAI-compatible client works.

| Parameter | Value |
|---|---|
| Base URL | `http://<MAC_LAN_IP>:10200/v1` (shown in the app; find your IP in System Settings → Wi-Fi → Details) |
| API key | contents of the endpoint's key file |
| Auth header | `Authorization: Bearer <key>` (also `x-api-key` or `x-opencodex-api-key`) |
| Model | the alias, `local-llm` by default; any other value gets 403 |
| Protocol | OpenAI Chat Completions with streaming; `/v1/responses` is proxied as well |

```sh
KEY=$(cat ~/.local/share/ocx-lan-filter/key)
curl -s http://<MAC_LAN_IP>:10200/v1/chat/completions \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"model":"local-llm","messages":[{"role":"user","content":"2+2?"}],"max_tokens":100}'
```

A ready-made prompt you can hand to an AI agent on the other device to set up opencode, Codex or another client:
[docs/client-setup-prompt.md](docs/client-setup-prompt.md) (Russian).

## What the filter allows

| Request | Result |
|---|---|
| no key or wrong key | 401 |
| `GET /v1/models` | 200, only the aliases of this endpoint; advertises `input_modalities: [text, image]` so clients do not strip images |
| `GET /healthz` | 200, alias and current real model |
| `POST /v1/chat/completions`, `POST /v1/responses` with an alias as `model` | proxied to `ocx` with the model swapped |
| same paths with any other `model` (including the real name) | 403 |
| any other path (`/api/keys`, `ocx` admin, …) | 404 |

## Files

| What | Path |
|---|---|
| Working copy of the filter | `~/.local/share/ocx-lan-filter/filter.py` |
| Config (endpoints, aliases, models) | `~/.local/share/ocx-lan-filter/config.json` |
| Listener status (written by the filter) | `~/.local/share/ocx-lan-filter/runtime.json` |
| Default endpoint key | `~/.local/share/ocx-lan-filter/key` (mode 600) |
| Keys of extra endpoints | `~/.local/share/ocx-lan-filter/keys/<id>.key` (mode 600) |
| Log | `~/.local/share/ocx-lan-filter/filter.log` |
| launchd service | `~/Library/LaunchAgents/com.local.ocx-lan-filter.plist` (label `com.local.ocx-lan-filter`) |
| CLI | `~/.local/bin/lanmodel` |

The working copy is separate from the source tree on purpose: launchd agents are often denied access to `~/Documents` (macOS TCC).
After editing `filter.py` in the source tree, run `./install.sh` again.

`config.json` v2 describes upstream and endpoints; the app writes it, the filter re-reads it every second (opens new ports, closes removed ones).
An invalid config is rejected as a whole, the last working one keeps running, and the reason is visible in `runtime.json` and in the app.
The old `{"upstream_model": "…"}` format is still read as endpoint `default` with alias `local-llm`.
Schema and validation rules: section 4.1 of [docs/menubar-app/PLAN.md](docs/menubar-app/PLAN.md) (Russian).

## Common tasks

```sh
# rotate a key (the old one stops working immediately; update your clients)
python3 -c "import secrets;print('lan_'+secrets.token_urlsafe(32),end='')" > ~/.local/share/ocx-lan-filter/key
chmod 600 ~/.local/share/ocx-lan-filter/key

# status and logs
launchctl print gui/$(id -u)/com.local.ocx-lan-filter | grep -E "state|pid"
tail -f ~/.local/share/ocx-lan-filter/filter.log

# uninstall
launchctl bootout gui/$(id -u)/com.local.ocx-lan-filter
rm ~/Library/LaunchAgents/com.local.ocx-lan-filter.plist
rm -r ~/.local/share/ocx-lan-filter ~/.local/bin/lanmodel
```

## Security notes

- Traffic is plain HTTP. That is fine on a trusted home network, not on public Wi-Fi. For anything else put a TLS tunnel in front.
- The filter does no rate limiting or accounting: everything that passes spends the quota of the accounts behind `ocx`.
- Pin the Mac's IP on your router (DHCP reservation). macOS "Rotating" private Wi-Fi address changes the MAC and breaks reservations;
  use "Fixed" or "Off" for that network.
- Listener hosts are limited to `0.0.0.0` and `127.0.0.1`. Keys are compared in constant time and never logged.
- Use "this Mac only" for endpoints that should not be reachable from the network.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Clients time out | The Mac is asleep, or its IP changed. Check the URL in the app and the router reservation. |
| 502 `upstream unavailable` | `ocx` is not running on `127.0.0.1:10100`. Start it (`ocx start`). |
| 401 | Missing or wrong key; the key may have been rotated. |
| 403 | The `model` is not one of the endpoint's aliases. |
| “Service not installed” won't go away | Make sure `python3` exists (`python3 --version`). The install error is shown in the app. |
| Model is marked orange | That model is no longer in the `ocx` catalog. Pick another one. |
| `lanmodel: command not found` | Add `~/.local/bin` to `PATH`. |
| App cannot be opened | See the “Open Anyway” / `xattr` step in [Install](#install). |

## Development

```sh
python3 -m unittest discover -s tests -t tests     # filter, CLI and shared validation fixtures
cd menubar && swift test                           # core logic and contract tests against the real filter.py
```

Layout: `filter.py` (data plane), `lanmodel` (CLI), `install.sh` + `launchd/` (service), `menubar/` (Swift package: `LanModelCore` logic,
`LanModelBar` UI), `tests/`, `docs/`. The app and the filter talk only through files (`config.json`, `runtime.json`).
Validation rules are duplicated in `filter.py` and `Validator.swift` and share `tests/fixtures/validation.json`.
Agent/contributor notes are in [AGENTS.md](AGENTS.md) (Russian).

## License

[MIT](LICENSE)
