# quarto-sync.nvim

[English README](README.md)

`quarto-sync.nvim` 是一个 Neovim 插件，同时内置一个 Quarto filter extension，用于在 `.qmd` 源文件和 Quarto HTML 预览页面之间做双向滚动同步。

插件会启动 `quarto preview`、启动一个本地同步服务，并监听 Neovim 中的光标移动。浏览器手动滚动时，也可以把当前可见的源码行同步回 Neovim。`:QSyncPreview` 会渲染一个临时的 shadow `.qmd` 文件，在其中插入不可见的源码行标记，然后浏览器端脚本根据这些标记定位。
对于 `project.type: website` 项目，`:QSyncPreview` 会使用临时 overlay project 预览，从而保留项目级 theme、CSS、navbar 和 sidebar 等网站样式配置。

## 功能

- `:QSyncPreview` 为当前 `.qmd` 文件启动 Quarto 预览。
- 内置 HTTP + Server-Sent Events 同步服务，不需要 Node.js 或额外 bridge 进程。
- Neovim 光标移动时，浏览器预览会根据源码行标记同步滚动。
- 浏览器手动滚动时，如果原始 `.qmd` 已在可见窗口中打开，Neovim 光标会移动到对应源码行。
- 带 label 的 figure、diagram、table、code cell 会优先使用 HTML anchor 定位。
- 浏览器端会短暂高亮当前同步到的预览块。
- `:QSyncInstallExtension` 可以把内置 Quarto extension 复制到当前项目。
- 命令统一使用 `QSync` 前缀，避免和 `quarto.nvim` 的 `Quarto*` 命令冲突。

## 需求

- Neovim 0.9+
- Quarto CLI，可通过 `quarto` 调用，或在配置中设置 `quarto_cmd`
- Quarto HTML 输出
- 支持 `EventSource` 的浏览器

## 安装

把本仓库作为普通 Neovim 插件安装即可。日常使用 `:QSyncPreview` 时，不需要在每个 `.qmd` 的 YAML 头中添加 `filters` 或 `port`。

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

### 本地开发

```lua
return {
  {
    dir = "~/Project/quarto-sync.nvim",
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

## 配置

插件有默认配置，也可以显式调用：

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

| 选项 | 默认值 | 说明 |
| --- | --- | --- |
| `host` | `"127.0.0.1"` | 本地同步服务监听地址。 |
| `port` | `18787` | 本地同步服务端口。 |
| `quarto_cmd` | `"quarto"` | Quarto 可执行文件。 |
| `browser_cmd` | `nil` | 可选浏览器命令，可以是字符串或列表。 |
| `open_browser` | `true` | 是否自动打开预览 URL。 |
| `preview_mode` | `"auto"` | 预览模式：`"auto"` 会对 `project.type: website` 使用 website overlay 预览，其他情况使用 document 预览；也可以强制设为 `"document"` 或 `"website"`。 |
| `sync_on_cursor_move` | `true` | 是否在光标移动时发送同步事件。 |
| `sync_from_browser` | `true` | 浏览器手动滚动时，是否移动 Neovim 光标到对应源码行。 |
| `debounce_ms` | `120` | 两次光标同步之间的最小间隔。 |
| `install_extension_if_missing` | `false` | 兼容保留项；`:QSyncPreview` 已经直接使用内置 filter。 |

## 命令

- `:QSyncPreview`：为当前 `.qmd` 文件启动同步预览。单文件预览使用隐藏的 shadow `.qmd`；website 项目使用临时 overlay project 以保留网站样式。插件会自动传入内置 sync filter。
- `:QSyncStop`：停止 Quarto 预览进程和本地同步服务，并清理 shadow 文件。
- `:QSyncRestart`：重启预览和同步服务。
- `:QSyncInstallExtension`：把 `_extensions/quarto-sync/` 复制到当前 Quarto 项目。
- `:QSyncInstallExtension!`：覆盖已有的 extension 文件。
- `:QSyncStatus`：显示 preview、server、port、原始文件、shadow 文件、预览 URL、最近同步行、最近浏览器同步行和最近识别到的 anchor。

命令只会在同名命令不存在时注册。

## 使用

1. 在 Neovim 中打开一个 `.qmd` 文件。
2. 运行 `:QSyncPreview`。
3. 在 Neovim 中移动光标，浏览器会滚动到对应的渲染位置。
4. 手动滚动浏览器预览，如果原始 `.qmd` 已在可见窗口中打开，Neovim 会把光标移动到对应源码行。
5. 修改内容后保存文件，shadow 文件会在 `BufWritePost` 自动重新生成。

在 Chrome DevTools 中，启用同步后页面里应该能搜到 `sync-scroll.js`、`.qsync-source-marker` 和 `data-qsync-source-line`。带 label 的图或代码块还应该有类似 `id="fig-example"` 或 `data-label="fig-example"` 的锚点。

## 是否需要写 filters 和 port

日常用 `:QSyncPreview` 时，不需要在每个 `.qmd` YAML 里写：

```yaml
filters:
  - quarto-sync

quarto-sync:
  port: 18787
```

原因是 `:QSyncPreview` 会自动传入内置 `--lua-filter`，并自动给浏览器 URL 添加 `qsyncPort=<port>`。

只有当你希望在 Neovim 之外运行普通 `quarto render` 或 `quarto preview` 时也注入同步脚本，才需要安装并启用 Quarto extension。通常把它写在项目级 `_quarto.yml` 中即可：

```yaml
filters:
  - quarto-sync
```

`port` 默认是 `18787`，一般也不需要写。只有你把 Neovim 端口改成别的值，并且还想让普通 Quarto render 出来的页面连接同一个端口时，才需要配置：

```yaml
quarto-sync:
  port: 18788
```

## Quarto Extension

`:QSyncPreview` 会直接使用仓库内置 filter，不依赖项目安装。document 预览会在源文件旁创建隐藏的 `.qsync-*.qmd`；website 预览会在 `/tmp/quarto-sync-*` 下创建临时 overlay project，以便 Quarto 在保留网站配置的同时渲染源码行标记。

如果你确实需要普通 Quarto 命令也带同步资源，可以在 `.qmd` buffer 中运行：

```vim
:QSyncInstallExtension
```

然后在 `_quarto.yml` 中启用：

```yaml
filters:
  - quarto-sync
```

这一步是可选的。

## 与 quarto.nvim 的兼容性

本插件不会定义 `:QuartoPreview`、`:QuartoClosePreview`、`:QuartoHelp`、`:QuartoActivate` 或任何 `:QuartoSend*` 命令。所有命令都使用 `QSync` 前缀，并且只在命令名未被占用时注册。

## 已知限制

- 浏览器到 Neovim 的反向同步要求原始 `.qmd` 已在 Neovim 可见窗口中打开；插件不会自动打开文件。
- 反向同步依赖 `:QSyncPreview` 生成的临时源码行标记。普通 Quarto render 即使安装了 extension，也不一定有足够的源码行标记用于反向定位。
- 主要支持单文件 `.qmd` 和 `project.type: website` HTML 预览。
- Quarto book、revealjs、PDF 输出和远程 SSH 浏览器转发还没有覆盖。
- Markdown 表格会作为一个同步区域处理，不做单元格级同步。
- code output、figure、table、callout 和 shortcode 可能定位到最近的源码行标记或 label anchor，而不是精确到行内位置。
- 建议给图、diagram 和可执行代码块添加 label，例如 `#| label: fig-example` 或 `%%| label: fig-example`，这样定位最稳。
- 插件不会自动修改 `_quarto.yml` 或 `.qmd` YAML。
- Website 预览会在 `/tmp` 下创建临时 overlay，并跳过 `_site`、`.quarto` 等生成目录，避免预览渲染写回源项目。
- `:QSyncPreview` 依赖 Quarto preview 对 `--lua-filter` 的转发行为；如果未来 Quarto 改变该行为，集成方式可能需要调整。

## 排障

- 如果 Chrome DevTools 中搜不到 `sync-scroll`、`.qsync-source-marker` 或 `data-qsync`，说明页面没有通过当前同步 filter 或 shadow source 渲染。运行 `:QSyncRestart`，并确认 URL 中包含 `qsyncPort=<port>`。
- 如果浏览器不滚动，运行 `:QSyncStatus`，确认 server 正在运行且 clients 数量大于 0。
- 如果浏览器滚动没有带动 Neovim，请确认原始 `.qmd` 仍在 Neovim 可见窗口中，并且 `sync_from_browser` 没有关闭。
- 如果图或 diagram 仍然只滚动到附近，检查 `:QSyncStatus` 中的 `last anchor`，它应该显示当前光标所在块的 label，例如 `fig-bn-three-variables`。
- 如果 Neovim 或 Quarto 异常退出，源文件旁边可能残留隐藏的 `.qsync-*.qmd` 文件。停止预览后可以安全删除。
- 如果 `18787` 端口被占用，在 Neovim setup 中改成其他端口，`:QSyncPreview` 会自动把该端口写进浏览器 URL。
- 如果没有自动打开浏览器，可以设置 `browser_cmd`，例如 `"firefox"`，或 macOS 上的 `{ "open", "-a", "Safari" }`。
- 如果 website overlay 模式在复杂项目中表现异常，可以设置 `preview_mode = "document"` 回退到旧的单文件预览路径。

## Roadmap

- 更好地清理异常退出后残留的 shadow 文件。
- WebSocket transport，用于更丰富的双向交互。
- 更好地支持 Quarto book。
- 多标签页状态管理。
- 远程开发工作流。

## License

MIT. See [LICENSE](LICENSE).
