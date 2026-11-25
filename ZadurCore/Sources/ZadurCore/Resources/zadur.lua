-- Zadur: makes markup from any scene (also from old versions) safe for every output format.

-- A link without a target ("[text]()") becomes its text. Typst refuses empty URLs.
function Link(el)
  if el.target == nil or el.target == "" then
    return el.content
  end
end

-- An image whose file isn't there becomes its caption, instead of failing the whole export.
function Image(el)
  if el.src:match("^%a[%w+.-]*://") then
    return nil
  end
  local file = io.open(el.src, "r")
  if file then
    file:close()
    return nil
  end
  return el.caption
end
