# QuotaPulse · 额度脉搏

[中文](./README.md)

A macOS menu bar app that shows your AI API quota / balance at a glance. No more tab-switching to check if you're about to run out of tokens.

Currently supports **GLM (Zhipu BigModel)** and **DeepSeek**.

## Features

- **GLM**: Shows 5h-window and 7-day-window quota usage percentages right in the menu bar. Color-coded by remaining quota (green → yellow → red). Click the menu to see exact reset countdowns.
- **DeepSeek**: Shows account balance in the menu bar. A colored dot indicates peak/off-peak billing (red = peak hours 9am–12pm & 2pm–6pm Shanghai time, ×2 rates). One-click toggle between Flash and Pro models.
- **Auto-refresh**: Fetches latest quota data every 5 minutes. Updates display colors every minute.
- **Local cache**: Works offline with cached data from the last successful fetch.
- **Pure menu bar**: No Dock icon, no windows, no interruptions. Just a number in your menu bar.

## Requirements

- macOS 12+
- Swift toolchain (for building from source)
- An API key for GLM (open.bigmodel.cn) or DeepSeek

## Quick Start

### Method 1: Use with CC Switch (current)

QuotaPulse reads your API key and provider selection automatically from [CC Switch](https://github.com/)'s local database. If you already use CC Switch to manage multiple AI coding tool providers, just install CC Switch and launch QuotaPulse — it auto-detects your current provider and key.

```bash
./build.sh
open ./outputs/QuotaPulse.app
```


### Method 2: Standalone (no CC Switch needed)

Don't want to install CC Switch? Paste your API key directly into QuotaPulse. Launch the app and, if no key is detected, a "Login / Configure API Key" item appears in the menu — click it to open a login window:

- **Choose provider**: GLM (Zhipu BigModel) or DeepSeek. The dropdown switches a hint showing where to get your key (GLM at open.bigmodel.cn → API Keys, DeepSeek at platform.deepseek.com user center)
- **Paste API Key**: a secure text field — input is masked
- **Login**: saves the config and immediately refreshes; the key is stored at `~/.codex/.quota-pulse-config.json`

Once logged in, the menu shows the current account and offers "Re-login" / "Log out". Logging out clears the manual config and falls back to env vars / CC Switch detection.

**Key resolution priority**: manual login config > environment variables (`GLM_API_KEY` / `ZHIPU_API_KEY` / `DEEPSEEK_API_KEY`) > CC Switch database. So no matter which method you use, QuotaPulse can find your key.

## Build from Source

```bash
git clone https://github.com/Drok1015/quota-pulse.git
cd quota-pulse
./build.sh
open ./outputs/QuotaPulse.app
```

The app starts silently in your menu bar. Look for the quota percentage or balance number.

## How It Works

- Queries GLM's `/api/monitor/usage/quota/limit` or DeepSeek's `/user/balance` endpoint
- Extracts your API key from CC Switch's SQLite database (`~/.cc-switch/cc-switch.db`)
- Renders a single number or percentage in the macOS menu bar, color-coded by remaining quota
- A pulldown menu shows detailed breakdown: time windows, reset countdowns, peak-hour status, balance breakdown, and model switcher

## Tech Stack

Single-file Swift native app (~500 lines). Compiled with `swiftc -O`. No dependencies beyond Foundation and Cocoa.

## License

MIT
