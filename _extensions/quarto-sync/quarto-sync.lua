local block_index = 0

local function is_html()
  if quarto and quarto.doc and quarto.doc.is_format then
    return quarto.doc.is_format("html")
  end
  return FORMAT:match("html") ~= nil
end

local function metadata_value(meta, key)
  local value = meta[key]
  if value == nil then
    return nil
  end
  return pandoc.utils.stringify(value)
end

local function sync_port(meta)
  local sync = meta["quarto-sync"]
  if type(sync) == "table" then
    local port = metadata_value(sync, "port")
    if port and tonumber(port) then
      return tonumber(port)
    end
  end
  return 18787
end

local function next_index()
  block_index = block_index + 1
  return tostring(block_index)
end

local function set_attribute(el, key, value)
  if el.attributes then
    el.attributes[key] = value
    return true
  end

  if el.attr then
    if el.attr.attributes then
      el.attr.attributes[key] = value
      return true
    end

    if type(el.attr) == "table" then
      el.attr[3] = el.attr[3] or {}
      el.attr[3][key] = value
      return true
    end
  end

  return false
end

local function mark_or_wrap(el)
  if not is_html() then
    return el
  end

  local index = next_index()
  if set_attribute(el, "data-qsync-block-index", index) then
    return el
  end

  return pandoc.Div({ el }, pandoc.Attr("", { "qsync-block" }, {
    ["data-qsync-block-index"] = index,
  }))
end

local function include_assets(meta)
  if not is_html() or not quarto or not quarto.doc then
    return meta
  end

  block_index = 0
  local port = sync_port(meta)
  quarto.doc.include_text("in-header", "<script>window.QUARTO_SYNC_PORT = " .. tostring(port) .. ";</script>")
  quarto.doc.add_html_dependency({
    name = "quarto-sync",
    version = "0.1.0",
    scripts = { "sync-scroll.js" },
    stylesheets = { "sync-scroll.css" },
  })

  return meta
end

return {
  {
    Meta = include_assets,
  },
  {
    Header = mark_or_wrap,
    Para = mark_or_wrap,
    CodeBlock = mark_or_wrap,
    BulletList = mark_or_wrap,
    OrderedList = mark_or_wrap,
    BlockQuote = mark_or_wrap,
    Div = mark_or_wrap,
    Table = mark_or_wrap,
  },
}
