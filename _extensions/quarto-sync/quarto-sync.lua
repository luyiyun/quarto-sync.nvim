local block_index = 0
local source_index = 0
local table_depth = 0

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

local function next_source_index()
  source_index = source_index + 1
  return tostring(source_index)
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

local function set_attributes(el, attrs)
  local ok = false
  for key, value in pairs(attrs) do
    ok = set_attribute(el, key, value) or ok
  end
  return ok
end

local function has_class(el, class_name)
  local classes = el.classes
  if not classes and el.attr then
    classes = el.attr.classes or el.attr[2]
  end
  if not classes then
    return false
  end

  for _, class in ipairs(classes) do
    if class == class_name then
      return true
    end
  end

  return false
end

local function classes(el)
  local value = el.classes
  if not value and el.attr then
    value = el.attr.classes or el.attr[2]
  end
  return value
end

local function has_any_class(el)
  local value = classes(el)
  return value ~= nil and #value > 0
end

local function identifier(el)
  if el.identifier then
    return el.identifier
  end
  if el.attr then
    return el.attr.identifier or el.attr[1] or ""
  end
  return ""
end

local function attributes(el)
  if el.attributes then
    return el.attributes
  end
  if el.attr then
    return el.attr.attributes or el.attr[3] or {}
  end
  return {}
end

local generated_div_classes = {
  ["callout-header"] = true,
  ["callout-icon-container"] = true,
  ["callout-title-container"] = true,
  ["callout-body-container"] = true,
  ["cell"] = true,
  ["cell-output-display"] = true,
  ["quarto-float"] = true,
  ["quarto-figure"] = true,
  ["quarto-figure-center"] = true,
  ["sourceCode"] = true,
}

local source_tags = {
  Header = true,
  Para = true,
  CodeBlock = true,
  BulletList = true,
  OrderedList = true,
  BlockQuote = true,
  Table = true,
}

local function is_generated_div(el)
  for class in pairs(generated_div_classes) do
    if has_class(el, class) then
      return true
    end
  end

  local attrs = attributes(el)
  if attrs["aria-describedby"] or attrs["data-layout-align"] then
    return true
  end

  return false
end

local function should_mark_source(tag, el)
  if table_depth > 0 and tag ~= "Table" then
    return false
  end

  if source_tags[tag] then
    return true
  end

  return false
end

local function mark_or_wrap(tag, el)
  if not is_html() then
    return el
  end
  if tag == "Div" and has_class(el, "qsync-source-marker") then
    return el
  end

  local attrs = {
    ["data-qsync-block-index"] = next_index(),
  }
  if should_mark_source(tag, el) then
    attrs["data-qsync-source-index"] = next_source_index()
  end

  if set_attributes(el, attrs) then
    return el
  end

  return pandoc.Div({ el }, pandoc.Attr("", { "qsync-block" }, {
    ["data-qsync-block-index"] = attrs["data-qsync-block-index"],
    ["data-qsync-source-index"] = attrs["data-qsync-source-index"],
  }))
end

local function mark(tag)
  return function(el)
    return mark_or_wrap(tag, el)
  end
end

local function mark_table(el)
  table_depth = table_depth + 1
  local walked = pandoc.walk_block(el, {
    Plain = mark("Plain"),
    Para = mark("Para"),
    CodeBlock = mark("CodeBlock"),
    BulletList = mark("BulletList"),
    OrderedList = mark("OrderedList"),
    BlockQuote = mark("BlockQuote"),
    Div = mark("Div"),
  })
  table_depth = table_depth - 1
  return mark_or_wrap("Table", walked)
end

local function include_assets(meta)
  if not is_html() or not quarto or not quarto.doc then
    return meta
  end

  block_index = 0
  source_index = 0
  table_depth = 0
  local port = sync_port(meta)
  quarto.doc.include_text("in-header", "<script>window.QUARTO_SYNC_PORT = " .. tostring(port) .. ";</script>")
  quarto.doc.add_html_dependency({
    name = "quarto-sync",
    version = "0.1.1",
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
    Header = mark("Header"),
    Para = mark("Para"),
    Plain = mark("Plain"),
    CodeBlock = mark("CodeBlock"),
    BulletList = mark("BulletList"),
    OrderedList = mark("OrderedList"),
    BlockQuote = mark("BlockQuote"),
    Div = mark("Div"),
    Table = mark_table,
    Figure = mark("Figure"),
  },
}
