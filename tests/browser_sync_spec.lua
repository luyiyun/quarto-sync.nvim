local preview = require("quarto_sync.preview")
local util = require("quarto_sync.util")

local uv = vim.uv or vim.loop

local function assert_equal(actual, expected, message)
  if actual ~= expected then
    error(("%s: expected %s, got %s"):format(message, vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local function module_state()
  for index = 1, 50 do
    local name, value = debug.getupvalue(preview.sync_from_browser, index)
    if not name then
      break
    end
    if name == "state" then
      return value
    end
  end
  error("could not find preview state upvalue")
end

local state = module_state()
local original_state = vim.deepcopy(state)
local bufnr = vim.api.nvim_create_buf(false, true)
local file = util.normalize(util.path_join(vim.fn.getcwd(), "tests/browser-sync-fixture.qmd"))

vim.api.nvim_buf_set_name(bufnr, file)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
  "one",
  "two",
  "three",
  "four",
  "five",
})
vim.api.nvim_win_set_buf(0, bufnr)
vim.api.nvim_win_set_cursor(0, { 2, 0 })

state.running = true
state.current_file = file
state.suppress_browser_until = uv.now() + 1000

assert_equal(
  preview.sync_from_browser({ type = "scroll", line = 4 }),
  false,
  "automatic browser scroll is ignored during save refresh"
)
assert_equal(vim.api.nvim_win_get_cursor(0)[1], 2, "ignored browser scroll keeps cursor position")

assert_equal(
  preview.sync_from_browser({ type = "scroll", line = 4, manual = true }),
  true,
  "manual browser scroll is accepted during save refresh"
)
assert_equal(vim.api.nvim_win_get_cursor(0)[1], 4, "manual browser scroll moves cursor")

vim.api.nvim_win_set_cursor(0, { 2, 0 })
state.suppress_browser_until = 0
assert_equal(
  preview.sync_from_browser({ type = "scroll", line = 3 }),
  true,
  "legacy browser scroll remains compatible outside save refresh"
)
assert_equal(vim.api.nvim_win_get_cursor(0)[1], 3, "legacy browser scroll moves cursor outside save refresh")

for key in pairs(state) do
  state[key] = nil
end
for key, value in pairs(original_state) do
  state[key] = value
end
