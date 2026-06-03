# quarto-sync.nvim

[中文文档](README.zh-CN.md)

`quarto-sync.nvim` is a minimal Neovim plugin plus Quarto extension for bidirectional synchronized scrolling between a `.qmd` buffer and the rendered Quarto HTML preview.

The plugin starts `quarto preview`, starts an internal local sync service, watches cursor movement in Neovim, and sends the current source position to the browser. Browser scrolling can also send the visible source line back to Neovim. `:QSyncPreview` renders a temporary shadow copy of the `.qmd` file with invisible source-line markers, while the Quarto extension injects a tiny browser script and fallback block markers into the rendered HTML.
For `project.type: website` projects, `:QSyncPreview` uses a temporary overlay project so project-level website theme, CSS, navbar, and sidebar settings are preserved.

## Features

- `:QSyncPreview` starts Quarto preview for the current `.qmd` file.
- Internal HTTP + Server-Sent Events service; no separate bridge process.
- Cursor movement in Neovim scrolls the browser preview using source-line markers.
- Manual scrolling in the browser moves the Neovim cursor to the matching source line when the source file is visible.
- Labeled Quarto blocks, figures, tables, and diagrams use anchor-based sync before source-line fallback.
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
    "luyiyun/quarto-sync.nvim",
    ft = { "quarto", "markdown" },
    main = "quarto_sync",
    opts = {
      port = 18787,
      quarto_cmd = "quarto",
      open_browser = true,
      preview_mode = "auto",
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
      preview_mode = "auto",
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
  preview_mode = "auto",
  sync_on_cursor_move = true,
  sync_from_browser = true,
  debounce_ms = 120,
  install_extension_if_missing = false,
})
```

## Commands

- `:QSyncPreview` starts the sync service and `quarto preview` for the current `.qmd` file. Single documents use a hidden shadow copy; website projects use a temporary overlay project that preserves project styling. It passes the bundled sync filter to Quarto automatically.
- `:QSyncPreviewDev` opens a `quarto-sync://preview-dev` scratch log buffer and starts or restarts preview in dev logging mode. The buffer records preview startup, Quarto job output, sync server requests, cursor/browser sync payloads, shadow refreshes, and cleanup events. It is in-memory only and does not write a log file.
- `:QSyncStop` stops the Quarto preview process and internal sync service, then removes the shadow file.
- `:QSyncRestart` restarts both preview and sync service.
- `:QSyncInstallExtension` copies `_extensions/quarto-sync/` into the current Quarto project.
- `:QSyncInstallExtension!` overwrites an existing installed copy.
- `:QSyncStatus` prints preview, server, port, source file, shadow file, URL, last synced line, last browser synced line, and last detected anchor.

Commands are only created if no command with the same name already exists.

## Quarto Extension

`:QSyncPreview` uses the bundled filter directly and does not require project installation. It creates a hidden `.qsync-*.qmd` file next to the original source for document preview, or a temporary `/tmp/quarto-sync-*` overlay project for website preview, so Quarto can preserve real source-line anchors in HTML.

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
3. Move the cursor in Neovim and the browser preview will scroll to the matching rendered source-line region.
4. Scroll the browser preview manually and Neovim will move the cursor to the matching source-line region if the source file is visible in a window.
5. Save the `.qmd` file when you change content; the shadow copy is regenerated on `BufWritePost`.

In Chrome DevTools, the rendered page should contain `sync-scroll.js`, `.qsync-source-marker`, and `data-qsync-source-line` when sync preview is active. Labeled figures and diagrams should also have an HTML anchor such as `id="fig-example"` or `data-label="fig-example"`.

## Configuration

| Option | Default | Description |
| --- | --- | --- |
| `host` | `"127.0.0.1"` | Local sync server host. |
| `port` | `18787` | Local sync server port. |
| `quarto_cmd` | `"quarto"` | Quarto executable. |
| `browser_cmd` | `nil` | Optional browser command. May be a string or list. |
| `open_browser` | `true` | Open the preview URL automatically. |
| `preview_mode` | `"auto"` | Preview mode: `"auto"` uses website overlay preview for `project.type: website` and document preview otherwise; `"document"` and `"website"` force a mode. |
| `sync_on_cursor_move` | `true` | Send cursor updates on movement. |
| `sync_from_browser` | `true` | Move the Neovim cursor when the browser preview is manually scrolled. |
| `debounce_ms` | `120` | Minimum time between cursor sync events. |
| `install_extension_if_missing` | `false` | Reserved for compatibility. `:QSyncPreview` now uses the bundled filter directly. |

## Compatibility with quarto.nvim

This plugin does not define `:QuartoPreview`, `:QuartoClosePreview`, `:QuartoHelp`, `:QuartoActivate`, or any `:QuartoSend*` command. All commands use the `QSync` prefix and are registered only when the command name is unused.

## Known Limitations

- Browser to Neovim sync requires the original `.qmd` file to be visible in a Neovim window; it will not open the file automatically.
- Reverse sync relies on the temporary source-line markers generated by `:QSyncPreview`. Regular Quarto renders with only the installed extension may not have enough source-line markers for reverse positioning.
- Source mapping uses temporary source-line markers for preview, then falls back to `data-qsync-source-index` / `data-qsync-block-index` for Neovim-to-browser sync when markers are absent.
- Markdown tables are treated as one sync region; table-cell-level sync is intentionally not attempted.
- Single-file `.qmd` and `project.type: website` HTML preview are the main supported paths.
- Quarto books, revealjs slides, PDF output, and remote SSH browser forwarding are not handled.
- Code output, figures, tables, callouts, and shortcodes may scroll to the nearest marker or labeled anchor rather than an exact inline position.
- Add labels such as `#| label: fig-example` or `%%| label: fig-example` to diagrams and executable blocks for the best sync accuracy.
- The plugin never edits `_quarto.yml` or `.qmd` YAML automatically.
- Website preview creates a temporary overlay under `/tmp` and skips generated project state such as `_site` and `.quarto` so preview renders do not write back into the source project.
- `:QSyncPreview` passes `--lua-filter` to Quarto. If a future Quarto version changes render argument forwarding for preview, this integration may need adjustment.

## Troubleshooting

- If Chrome DevTools cannot find `sync-scroll`, `.qsync-source-marker`, or `data-qsync`, the page was rendered without the filter or without the shadow source. Run `:QSyncRestart` and make sure the page URL includes `qsyncPort=<port>`.
- If the browser does not move, check `:QSyncStatus` and confirm the server is running.
- If browser scrolling does not move Neovim, keep the original `.qmd` visible in a Neovim window and make sure `sync_from_browser` is enabled.
- If diagrams or figures still land nearby instead of exactly, check `:QSyncStatus`; `last anchor` should show the label under the cursor, for example `fig-bn-three-variables`.
- If Neovim or Quarto exits unexpectedly, a hidden `.qsync-*.qmd` file may be left next to the source file. It is safe to delete after preview is stopped.
- If port `18787` is busy, set another `port` in Neovim setup. `:QSyncPreview` will append that port to the browser URL.
- If the preview URL is not detected, run `quarto preview <file> --no-browser` manually and check that Quarto prints a local `http://...` URL.
- If a website project behaves oddly in overlay mode, set `preview_mode = "document"` to fall back to the old single-document preview path.
- If no browser opens, set `browser_cmd`, for example `"firefox"` or `{ "open", "-a", "Safari" }` on macOS.

## Roadmap

- Optional cleanup of stale shadow files after unexpected crashes.
- WebSocket transport for richer two-way interactions.
- Better support for Quarto books.
- Multi-tab state handling.
- Remote development workflows.
