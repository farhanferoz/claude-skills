--[[
auto_table_widths.lua — proportional table column widths at build time.

Problem this solves (recurring, user-flagged):
  Pandoc pipe tables with a uniform `|---|---|` delimiter give every column an
  equal share of the page. A two-column "Symbol | Meaning" table then hands the
  tiny symbol column half the width, leaving a large empty gap before the text.

  The naive fix — width proportional to each column's longest *cell* — fails the
  opposite way on a wide table with one long-prose column: that column's 150-char
  cell dominates the proportion and starves the short columns below the width of
  their own longest word, so a header like "Regulatory" wraps mid-word to
  "Regulator-y". (Observed: the venue-comparison table, 3 cols, one long-prose col.)

Fix (word-aware floor, then proportional remainder):
  1. floor[j] = the width the column needs so its longest UNBREAKABLE token (a
     word, splitting at spaces, hyphens, underscores, slashes — LaTeX's break
     points) never wraps mid-word. Expressed as a fraction of the text measure
     via CAP, an estimate of characters-per-line at the body size.
  2. Hand every column its floor first; distribute the LEFTOVER width
     proportional to each column's longest cell (so the prose column still gets
     the lion's share, the label column stays snug — the original intent).
  3. If the floors alone exceed the target (a genuinely too-dense table), scale
     them down proportionally rather than overflow.
  Authors write plain `|---|` and never tune dashes. Deterministic.

Heuristic for "rendered length":
  Stringify the cell, then discount LaTeX-math markup that inflates the raw
  character count ($, control words \foo, and { } _ ^), so `$\mu(x),\sigma(x)$`
  is measured at roughly its on-page width, not its source width.

Tuning knobs:
  TARGET  total width fraction (<1 leaves room for inter-column padding so the
          table never overflows the right margin).
  CAP     assumed characters-per-line for the full text measure at the body
          size; the word floor is longest-word / CAP. Lower = safer against
          mid-word wraps (wider floors), at the cost of denser tables degrading
          sooner. ~80 suits 11pt Palatino over the template's ~7.3in measure.
  FLOOR   hard minimum per-column fraction, a backstop for empty/symbol columns.
]]

local TARGET = 0.96
local CAP = 80
local FLOOR = 0.04

-- Strip math markup so a cell is measured at ~its on-page glyph width.
local function clean(cell)
  local s = pandoc.utils.stringify(cell.contents)
  s = s:gsub('%$', '')              -- math delimiters take no width
  s = s:gsub('\\[a-zA-Z]+', 'xx')   -- a control word renders ~2 glyphs on average
  s = s:gsub('[{}_%^]', '')         -- grouping/scripts take no width
  return s
end

-- Whole-cell display length (drives the proportional remainder).
local function disp_len(cell)
  local s = clean(cell)
  local n = utf8 and utf8.len(s) or #s
  return math.max(n or #s, 1)
end

-- Longest unbreakable token: split at the points LaTeX can break a line
-- (space, hyphen, underscore, slash). Drives the per-column word floor.
local function word_len(cell)
  local s = clean(cell)
  s = s:gsub('[%-_/]', ' ')
  local longest = 1
  for tok in s:gmatch('%S+') do
    local n = (utf8 and utf8.len(tok)) or #tok
    if n and n > longest then longest = n end
  end
  return longest
end

local function scan(rows, natural, word)
  for _, row in ipairs(rows) do
    for j, cell in ipairs(row.cells) do
      local d = disp_len(cell)
      local w = word_len(cell)
      if not natural[j] or d > natural[j] then natural[j] = d end
      if not word[j] or w > word[j] then word[j] = w end
    end
  end
end

function Table(tbl)
  local ncol = #tbl.colspecs
  if ncol == 0 then return nil end

  local natural, word = {}, {}
  scan(tbl.head.rows, natural, word)
  for _, body in ipairs(tbl.bodies) do
    scan(body.head, natural, word)
    scan(body.body, natural, word)
  end
  for j = 1, ncol do natural[j] = natural[j] or 1; word[j] = word[j] or 1 end

  -- 1. Per-column word floor: enough width that the longest word never breaks.
  local floor = {}
  local floor_sum = 0
  for j = 1, ncol do
    floor[j] = math.max(FLOOR, math.min(word[j] / CAP, 0.6))
    floor_sum = floor_sum + floor[j]
  end

  -- 2/3. Distribute the leftover proportional to each column's longest cell;
  --      if floors alone exceed the target, scale them down to fit.
  local nat_sum = 0
  for j = 1, ncol do nat_sum = nat_sum + natural[j] end

  local w = {}
  if floor_sum >= TARGET then
    for j = 1, ncol do w[j] = TARGET * floor[j] / floor_sum end
  else
    local leftover = TARGET - floor_sum
    for j = 1, ncol do
      local share = nat_sum > 0 and (natural[j] / nat_sum) or (1 / ncol)
      w[j] = floor[j] + leftover * share
    end
  end

  for j = 1, ncol do tbl.colspecs[j][2] = w[j] end
  return tbl
end
