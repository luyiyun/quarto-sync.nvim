# quarto-sync.nvim

`quarto-sync.nvim` is a minimal Neovim plugin plus Quarto extension for one-way synchronized scrolling from a `.qmd` buffer to the rendered Quarto HTML preview.

The plugin starts `quarto preview`, starts an internal local sync service, watches cursor movement in Neovim, and sends the current source position to the browser. The Quarto extension injects a tiny browser script and best-effort block markers into the rendered HTML.

## Features

- `:QSyncPreview` starts Quarto preview for the current `.qmd` file.
- Internal HTTP + Server-Sent Events service; no separate bridge process.
- Cursor movement in Neovim scrolls the browser preview to a nearby block.
- Lightweight highlight for the current preview block.
- `:QSyncInstallExtension` copies the bundled Quarto extension into the current project.
- Commands use the `QSync` prefix so they can coexist with `quarto.nvim`.

## Requirements

- Neovim 0.9+.
- Quarto CLI available as `quarto`, or configured with `quarto_cmd`.
- HTML output from Quarto.
- A browser with `EventSource` support.

## Installation

Install this repository as a normal Neovim plugin. `:QSyncPreview` automatically applies the bundled Quarto filter, so you do not need to edit `_quarto.yml` just to use synced preview from Neovim.

### LazyVim

```lua
-- ~/.config/nvim/lua/plugins/quarto-sync.lua
return {
  {
    "your-github-name/quarto-sync.nvim",
    ft = { "quarto", "markdown" },
    main = "quarto_sync",
    opts = {
      port = 18787,
      quarto_cmd = "quarto",
      open_browser = true,
      debounce_ms = 120,
    },
  },
}
```

### Local Development

```lua
return {
  {
    dir = "~/Projects/quarto-sync.nvim",
    ft = { "quarto", "markdown" },
    main = "quarto_sync",
    opts = {
      port = 18787,
      quarto_cmd = "quarto",
      open_browser = true,
      debounce_ms = 120,
    },
  },
}
```

## Setup

Defaults are applied automatically, but explicit setup is supported:

```lua
require("quarto_sync").setup({
  port = 18787,
  quarto_cmd = "quarto",
  browser_cmd = nil,
  open_browser = true,
  sync_on_cursor_move = true,
  debounce_ms = 120,
  install_extension_if_missing = false,
})
```

## Commands

- `:QSyncPreview` starts the sync service and `quarto preview` for the current `.qmd` file. It passes the bundled sync filter to Quarto automatically.
- `:QSyncStop` stops the Quarto preview process and internal sync service.
- `:QSyncRestart` restarts both preview and sync service.
- `:QSyncInstallExtension` copies `_extensions/quarto-sync/` into the current Quarto project.
- `:QSyncInstallExtension!` overwrites an existing installed copy.
- `:QSyncStatus` prints preview, server, port, file, URL, and last synced line.

Commands are only created if no command with the same name already exists.

## Quarto Extension

`:QSyncPreview` uses the bundled filter directly and does not require project installation.

Install the extension only if you also want normal `quarto render` or `quarto preview` outside Neovim to include sync assets. From a `.qmd` buffer in your Quarto project, run:

```vim
:QSyncInstallExtension
```

Then enable the filter in `_quarto.yml`:

```yaml
filters:
  - quarto-sync
```

Or enable it in a single `.qmd` file:

```yaml
---
title: "My Note"
format: html
filters:
  - quarto-sync
---
```

The browser script defaults to port `18787`. During `:QSyncPreview`, the plugin appends `qsyncPort=<port>` to the browser URL automatically. For regular Quarto commands outside Neovim, override the port in YAML when needed:

```yaml
quarto-sync:
  port: 18788
```

## Usage

1. Open a `.qmd` file in Neovim.
2. Run `:QSyncPreview`.
3. Move the cursor in Neovim and the browser preview will scroll to a nearby rendered block.

In Chrome DevTools, the rendered page should contain `sync-scroll.js` and `data-qsync-block-index` when sync preview is active.

## Configuration

| Option | Default | Description |
| --- | --- | --- |
| `host` | `"127.0.0.1"` | Local sync server host. |
| `port` | `18787` | Local sync server port. |
| `quarto_cmd` | `"quarto"` | Quarto executable. |
| `browser_cmd` | `nil` | Optional browser command. May be a string or list. |
| `open_browser` | `true` | Open the preview URL automatically. |
| `sync_on_cursor_move` | `true` | Send cursor updates on movement. |
| `debounce_ms` | `120` | Minimum time between cursor sync events. |
| `install_extension_if_missing` | `false` | Reserved for compatibility. `:QSyncPreview` now uses the bundled filter directly. |

## Compatibility with quarto.nvim

This plugin does not define `:QuartoPreview`, `:QuartoClosePreview`, `:QuartoHelp`, `:QuartoActivate`, or any `:QuartoSend*` command. All commands use the `QSync` prefix and are registered only when the command name is unused.

## Known Limitations

- MVP supports Neovim to browser sync only.
- Source mapping is best-effort block-level mapping. Pandoc/Quarto Lua filters do not reliably expose original `.qmd` line numbers for every block, so this version injects `data-qsync-block-index` markers and estimates the source block from the cursor line.
- Single-file `.qmd` preview is the main supported path.
- Quarto books, websites, revealjs slides, PDF output, and remote SSH browser forwarding are not handled.
- Code output, figures, tables, callouts, and shortcodes may scroll to a nearby block rather than an exact source line.
- The plugin never edits `_quarto.yml` or `.qmd` YAML automatically.
- `:QSyncPreview` passes `--lua-filter` to Quarto. If a future Quarto version changes render argument forwarding for preview, this integration may need adjustment.

## Troubleshooting

- If Chrome DevTools cannot find `sync-scroll` or `data-qsync`, the page was rendered without the filter. Run `:QSyncRestart` and make sure the page URL includes `qsyncPort=<port>`.
- If the browser does not move, check `:QSyncStatus` and confirm the server is running.
- If port `18787` is busy, set another `port` in Neovim setup. `:QSyncPreview` will append that port to the browser URL.
- If the preview URL is not detected, run `quarto preview <file> --no-browser` manually and check that Quarto prints a local `http://...` URL.
- If no browser opens, set `browser_cmd`, for example `"firefox"` or `{ "open", "-a", "Safari" }` on macOS.

## Roadmap

- More accurate source line mapping when Quarto/Pandoc exposes reliable source positions.
- WebSocket transport for richer two-way interactions.
- Browser to Neovim reverse jump.
- Better support for Quarto books and websites.
- Multi-tab state handling.
- Remote development workflows.
