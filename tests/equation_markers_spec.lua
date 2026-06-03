local source_markers = require("quarto_sync.source_markers")
local util = require("quarto_sync.util")

local function assert_equal(actual, expected, message)
  if actual ~= expected then
    error(("%s: expected %s, got %s"):format(message, vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local function assert_false(actual, message)
  if actual then
    error(("%s: expected false, got %s"):format(message, vim.inspect(actual)), 2)
  end
end

assert_equal(util.is_display_math_delimiter("$$"), true, "bare display math delimiter")
assert_equal(util.is_display_math_delimiter("$$ {#eq-gmm}"), true, "spaced equation label delimiter")
assert_equal(util.display_math_label("$$ {#eq-gmm}"), "eq-gmm", "spaced equation label")
assert_equal(
  util.is_display_math_delimiter("$$ {#eq-gmm .unnumbered}"),
  true,
  "spaced equation label with attributes"
)
assert_equal(util.display_math_label("$$ {#eq-gmm .unnumbered}"), "eq-gmm", "spaced equation label with attributes")
assert_equal(util.is_display_math_delimiter("$${#eq-gmm}"), true, "compact equation label delimiter")
assert_equal(util.display_math_label("$${#eq-gmm}"), "eq-gmm", "compact equation label")
assert_equal(
  util.display_math_label("$${#eq-second .unnumbered}"),
  "eq-second",
  "compact equation label with attributes"
)
assert_false(util.is_display_math_delimiter("$$#eq-gmm"), "unbraced equation label")

local lines = {
  "---",
  "format: html",
  "---",
  "",
  "GMM log likelihood",
  "$$",
  "x=1",
  "$${#eq-gmm}",
  "After first equation.",
  "",
  "Continuing content.",
  "",
  "$$",
  "y=2",
  "$${#eq-second}",
  "After second equation.",
}

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

local first_equation = util.cursor_context(bufnr, 6)
assert_equal(first_equation.source_index, 1, "first equation source index")
assert_equal(first_equation.block_index, 1, "first equation block index")
assert_equal(first_equation.anchor, "eq-gmm", "first equation anchor")

local after_first = util.cursor_context(bufnr, 9)
assert_equal(after_first.source_index, 2, "content after compact labeled equation source index")
assert_equal(after_first.block_index, 2, "content after compact labeled equation block index")

local second_equation = util.cursor_context(bufnr, 13)
assert_equal(second_equation.source_index, 4, "second equation source index")
assert_equal(second_equation.block_index, 4, "second equation block index")
assert_equal(second_equation.anchor, "eq-second", "second equation anchor")

local after_second = util.cursor_context(bufnr, 16)
assert_equal(after_second.source_index, 5, "content after second compact labeled equation source index")
assert_equal(after_second.block_index, 5, "content after second compact labeled equation block index")

local instrumented = source_markers.instrument_lines(lines)
for index, line in ipairs(instrumented) do
  if line == "$$" then
    local next_line = instrumented[index + 1] or ""
    if next_line:find("qsync-source-marker", 1, true) then
      error(("source marker was inserted inside display math at output line %d"):format(index + 1))
    end
  end
end

local joined = table.concat(instrumented, "\n")
assert_equal(
  joined:find('<div class="qsync-source-marker" data-qsync-source-line="16"></div>', 1, true) ~= nil,
  true,
  "marker after second compact labeled equation"
)
