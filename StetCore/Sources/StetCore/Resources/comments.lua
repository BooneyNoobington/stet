-- Stet: a Pandoc writer that lists the comments of a Word document as JSON:
-- [{ "author": …, "date": …, "text": …, "anchor": <the commented passage> }, …]
-- Use with: pandoc --from=docx --track-changes=all --to=comments.lua

local comments = {}
local open = {}

local function add_to_open(text)
  for _, index in pairs(open) do
    comments[index].anchor = comments[index].anchor .. text
  end
end

-- Pandoc reads the id as "comment-id" (older versions: "id").
local function comment_id(el)
  return el.attributes["comment-id"] or el.attributes.id or tostring(#comments)
end

local function walk_inlines(inlines)
  for _, el in ipairs(inlines) do
    if el.t == "Span" and el.classes:includes("comment-start") then
      table.insert(comments, {
        author = el.attributes.author or "",
        date = el.attributes.date or "",
        text = pandoc.utils.stringify(el.content),
        anchor = "",
      })
      open[comment_id(el)] = #comments
    elseif el.t == "Span" and el.classes:includes("comment-end") then
      open[comment_id(el)] = nil
    elseif el.t == "Space" or el.t == "SoftBreak" or el.t == "LineBreak" then
      add_to_open(" ")
    elseif el.content and type(el.content) == "table" and el.t ~= "Note" then
      walk_inlines(el.content)
    elseif el.t ~= "Note" then
      add_to_open(pandoc.utils.stringify(el))
    end
  end
end

local function walk_blocks(blocks)
  for _, block in ipairs(blocks) do
    if block.t == "Para" or block.t == "Plain" or block.t == "Header" then
      walk_inlines(block.content)
      add_to_open(" ")
    elseif block.content and type(block.content) == "table" then
      walk_blocks(block.content)
    end
  end
end

function Writer(doc, opts)
  walk_blocks(doc.blocks)
  return pandoc.json.encode(comments)
end
