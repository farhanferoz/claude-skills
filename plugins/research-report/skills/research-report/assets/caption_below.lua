--[[
caption_below.lua — table captions render BELOW the table, matching figures.

Problem this solves (user-flagged, 2026-08-12):
  Pandoc's LaTeX writer emits a longtable's \caption INSIDE the table environment
  and BEFORE the first \toprule, so a table caption lands above its table while
  every figure caption lands below its image. The document then reads with two
  different caption conventions, and the eye has to learn both.

Fix:
  Strip the caption off the Table node (so pandoc emits a bare longtable) and
  re-emit it immediately after the table as \captionof{table}{...}. \captionof
  (caption package, loaded in book_chapter.tex) steps the table counter and
  formats identically to a real \caption, so numbering, styling and \label all
  behave — it simply is not inside the environment.

  LaTeX output only; every other writer keeps pandoc's own caption handling.

Second defect, found 2026-08-13 by a cold reader who noticed the appendix's
tables ran 24, 26, 28, 30 — every number even, every odd one skipped:
  `longtable` steps the `table` counter ITSELF, once per environment, whether
  or not the environment carries a caption. `\captionof{table}` then steps it
  again, so a captioned longtable consumes TWO numbers and the visible ones
  advance in twos. Measured on a two-table minimal document: "Table 2, Table 4"
  before the fix, "Table 1, Table 2" after.
  So every branch below gives the counter back the step longtable already took:
  a captioned table decrements and then lets \captionof re-step it (which must
  stay a \refstepcounter, or \label would break), and an UNCAPTIONED table
  decrements and stops — an unnumbered table should not eat a number at all.
]]

if not FORMAT:match('latex') then return {} end

-- Undo the step `longtable` takes on its own for every environment it opens.
local GIVE_BACK = '\\addtocounter{table}{-1}'

function Table(tbl)
  local long = tbl.caption and tbl.caption.long

  -- No caption: the table is unnumbered, so it must not consume a number.
  if not long or #long == 0 then
    return { tbl, pandoc.RawBlock('latex', GIVE_BACK) }
  end

  local latex = pandoc.write(pandoc.Pandoc(long), 'latex'):gsub('%s+$', '')
  -- ⛔ `pandoc.Caption` is a pandoc >= 3.6 constructor and is NIL on older
  -- pandoc: on the 3.1.3 installed here it raised "attempt to call a nil value
  -- (field 'Caption')" the first time a captioned table was built (2026-09-10).
  -- The preflight did not catch it because its test document has no caption, so
  -- this branch never ran. Clearing the caption's `long` field in place needs no
  -- constructor and behaves identically on both APIs.
  tbl.caption.long = pandoc.Blocks({})

  -- The caption sits in a brace group. \captionof outside a float sets the caption
  -- package's options (among them a zero \parskip) at the CURRENT group level, so
  -- emitted bare it leaked them into the rest of the document: every paragraph
  -- after a report's first table lost its gap (found by a cold reader on the
  -- 2026-10-14 model findings note, which had to patch around it in preamble.tex).
  -- The counter steps stay global, so numbering is unchanged.
  return {
    tbl,
    pandoc.RawBlock('latex', GIVE_BACK .. '{\\captionof{table}{' .. latex .. '}}'),
  }
end
