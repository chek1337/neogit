local diff = require("neogit.lib.git.diff")

local eq = assert.are.same

describe("lib.git.diff.build_pager_line_mapping", function()
  it("returns an identity mapping when content matches the diff verbatim", function()
    local hunk_lines = {
      " context",
      "+added",
      "-removed",
      " trailing",
    }
    -- Pager that does not decorate (e.g. cat).
    local content = {
      " context",
      "+added",
      "-removed",
      " trailing",
    }

    eq({ 1, 2, 3, 4 }, diff.build_pager_line_mapping(content, hunk_lines))
  end)

  it("skips decoration lines added by delta", function()
    local hunk_lines = {
      "   local virtual_text",
      "",
      "   -- Render margin, if visible",
      '-  if state.get({ "margin", "visibility" }, false) then',
      '+  if state.get({ "margin", "visibility" }, true) then',
    }
    -- Faithful (ANSI-stripped) reproduction of `git diff | delta` output for
    -- one hunk, including the file header, section divider, expanded section
    -- header from delta's `decoration` style, and line-numbered content rows.
    local content = {
      "Δ lua/neogit/buffers/status/ui.lua",
      "────────────────────────────────────────────────────────────────────────────────────────────────────",
      "",
      "──────────────────────────────────────────────────────────────┐",
      "• 399: local SectionItemCommit = Component.new(function(item) │",
      "──────────────────────────────────────────────────────────────┘",
      " 399⋮ 399│  local virtual_text",
      " 400⋮ 400│",
      " 401⋮ 401│  -- Render margin, if visible",
      ' 402⋮    │  if state.get({ "margin", "visibility" }, false) then',
      '    ⋮ 402│  if state.get({ "margin", "visibility" }, true) then',
    }

    local mapping = diff.build_pager_line_mapping(content, hunk_lines)

    -- First six lines are decoration and must be reported as such, the next
    -- five lines map back to the original diff in order.
    eq({
      [1] = false,
      [2] = false,
      [3] = false,
      [4] = false,
      [5] = false,
      [6] = false,
      [7] = 1,
      [8] = 2,
      [9] = 3,
      [10] = 4,
      [11] = 5,
    }, mapping)
  end)

  it("matches `+`/`-` content from pagers that keep the diff prefix", function()
    -- A pager (or delta with `line-numbers = false`) that keeps the original
    -- +/- prefix and only colorizes the line.
    local hunk_lines = {
      "-old",
      "+new",
      " context",
    }
    local content = {
      "-old",
      "+new",
      " context",
    }

    eq({ 1, 2, 3 }, diff.build_pager_line_mapping(content, hunk_lines))
  end)
end)
