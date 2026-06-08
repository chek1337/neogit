local a = require("neogit.lib.async")
local git = require("neogit.lib.git")
local util = require("neogit.lib.util")
local config = require("neogit.config")
local logger = require("neogit.logger")

local insert = table.insert
local sha256 = vim.fn.sha256

---@class NeogitGitDiff
---@field parse fun(raw_diff: string[], raw_stats: string[]): Diff
---@field build fun(section: string, file: StatusItem)
---@field staged_stats fun(): DiffStagedStats
---@field build_pager_line_mapping fun(content: string[], hunk_lines: string[]): (integer|false)[]
---
---@class Diff
---@field kind string
---@field lines string[]
---@field file string
---@field info table
---@field stats table
---@field hunks Hunk
---@field pager_contents string[]
---
---@class DiffStats
---@field additions number
---@field deletions number
---
---@class Hunk
---@field file string
---@field index_from number
---@field index_len number
---@field disk_from number
---@field disk_len number
---@field diff_from number
---@field diff_to number
---@field length number
---@field pager_length? number When a `log_pager` is active, total rendered
---  rows for the hunk (the decorated output replaces the raw diff lines, so
---  buffer extents must be derived from this length instead of `length`).
---@field hash string
---@field first number First line number in buffer
---@field last number Last line number in buffer
---@field lines string[]
---@field pager_line_mapping? (integer|false)[] When a `log_pager` is active,
---  maps each pager-rendered line index to its index in `lines`. `false`
---  entries denote decoration lines (filename header, dividers, expanded
---  context) which should not be jumpable.
---
---@class DiffStagedStats
---@field summary string
---@field files DiffStagedStatsFile
---
---@class DiffStagedStatsFile
---@field path string|nil
---@field changes string|nil
---@field insertions string|nil
---@field deletions string|nil

---@param raw string|string[]
---@return DiffStats
local function parse_diff_stats(raw)
  if type(raw) == "string" then
    raw = vim.split(raw, ", ")
  end
  local stats = {
    additions = 0,
    deletions = 0,
  }

  -- local matches raw:match('1 file changed, (%d+ insertions?%(%+%))?(, )?(%d+ deletions?%(%-%))?')
  for _, part in ipairs(raw) do
    part = util.trim(part)
    local additions = part:match("(%d+) insertion.*")
    local deletions = part:match("(%d+) deletion.*")

    if additions then
      stats.additions = tonumber(additions)
    end

    if deletions then
      stats.deletions = tonumber(deletions)
    end
  end

  return stats
end

---@param output string[]
---@return string[], number
local function build_diff_header(output)
  local header = {}
  local start_idx = 1

  for i = start_idx, #output do
    local line = output[i]
    if line:match("^@@@*.*@@@*") then
      start_idx = i
      break
    end

    insert(header, line)
  end

  return header, start_idx
end

---@param header string[]
---@param kind string
---@return string
local function build_file(header, kind)
  if kind == "modified" then
    return header[3]:match("%-%-%- ./(.*)")
  elseif kind == "renamed" then
    return ("%s -> %s"):format(header[3]:match("rename from (.*)"), header[4]:match("rename to (.*)"))
  elseif kind == "new file" then
    return header[5]:match("%+%+%+ b/(.*)")
  elseif kind == "deleted file" then
    return header[4]:match("%-%-%- a/(.*)")
  else
    return ""
  end
end

---@param header string[]
---@return string, string[]
local function build_kind(header)
  local kind = ""
  local info = {}
  local header_count = #header

  if header_count >= 4 and header[2]:match("^similarity index") then
    kind = "renamed"
    info = { header[3], header[4] }
  elseif header_count == 4 then
    kind = "modified"
  elseif header_count == 5 then
    kind = header[2]:match("(.*) mode %d+") or header[3]:match("(.*) mode %d+")
  else
    logger.debug(vim.inspect(header))
  end

  return kind, info
end

---@param output string[]
---@param start_idx number
---@return string[]
local function build_lines(output, start_idx)
  local lines = {}

  if start_idx == 1 then
    lines = output
  else
    for i = start_idx, #output do
      insert(lines, output[i])
    end
  end

  return lines
end

---@param content string[]
---@return string
local function hunk_hash(content)
  return sha256(table.concat(content, "\n"))
end

---@param lines string[]
---@return Hunk
local function build_hunks(lines)
  local hunks = {}
  local hunk = nil
  local hunk_content = {}

  for i = 1, #lines do
    local line = lines[i]
    if not line:match("^%+%+%+") then
      local index_from, index_len, disk_from, disk_len

      if line:match("^@@@") then
        -- Combined diff header
        index_from, index_len, disk_from, disk_len = line:match("^@@@* %-(%d+),?(%d*) .* %+(%d+),?(%d*) @@@*")
      else
        -- Normal diff header
        index_from, index_len, disk_from, disk_len = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
      end

      if index_from then
        if hunk ~= nil then
          hunk.hash = hunk_hash(hunk_content)
          hunk_content = {}
          insert(hunks, hunk)
        end

        hunk = {
          index_from = tonumber(index_from),
          index_len = tonumber(index_len) or 1,
          disk_from = tonumber(disk_from),
          disk_len = tonumber(disk_len) or 1,
          line = line,
          diff_from = i,
          diff_to = i,
        }
      else
        insert(hunk_content, line)

        if hunk then
          hunk.diff_to = hunk.diff_to + 1
        end
      end
    end
  end

  if hunk then
    hunk.hash = hunk_hash(hunk_content)
    insert(hunks, hunk)
  end

  for _, hunk in ipairs(hunks) do
    hunk.lines = {}
    for i = hunk.diff_from + 1, hunk.diff_to do
      insert(hunk.lines, lines[i])
    end

    hunk.length = hunk.diff_to - hunk.diff_from
  end

  return hunks
end

---Match a pager-rendered line against the next expected diff line. Used to
---map cursor positions in a pager-decorated hunk back to the underlying diff.
---@param pager_stripped string Pager line with ANSI escapes removed
---@param orig_line string Original diff line (with `+`/`-`/` ` prefix)
---@return boolean
local function pager_line_matches(pager_stripped, orig_line)
  local orig_content = orig_line:sub(2)

  -- Content after the last `│` separator (delta with line-numbers)
  local after_bar = pager_stripped:match(".*│([^│]*)$")
  -- Trailing run that could carry the diff content (delta without line-numbers,
  -- or other pagers).
  local trailing = pager_stripped

  if orig_content == "" then
    if after_bar ~= nil then
      return after_bar:match("^%s*$") ~= nil
    end
    return trailing:match("^%s*$") ~= nil
  end

  if after_bar ~= nil then
    return after_bar == orig_content
  end

  if #trailing >= #orig_content and trailing:sub(-#orig_content) == orig_content then
    return true
  end

  return false
end

---Build a mapping `pager_index -> hunk.lines index` so cursor positions inside
---the pager-rendered hunk can be resolved to the underlying diff lines. Lines
---that the pager added as decoration (filename headers, section dividers,
---expanded context, etc.) are mapped to `false` so callers can treat them as
---non-jumpable.
---@param content string[] Pager output for this hunk
---@param hunk_lines string[] Original diff lines for the hunk (no header)
---@return (integer|false)[]
local function build_pager_line_mapping(content, hunk_lines)
  local mapping = {}
  local orig_idx = 1

  for pager_idx, line in ipairs(content) do
    local stripped = util.remove_ansi_escape_codes(line)
    local matched = false

    if orig_idx <= #hunk_lines and pager_line_matches(stripped, hunk_lines[orig_idx]) then
      mapping[pager_idx] = orig_idx
      orig_idx = orig_idx + 1
      matched = true
    end

    if not matched then
      mapping[pager_idx] = false
    end
  end

  return mapping
end

---@param diff_header string[]
---@param lines string[]
---@param hunks Hunk[]
---@return string[][], (integer|false)[][]
local function build_pager_contents(diff_header, lines, hunks)
  local res = {}
  local mappings = {}

  if config.values.log_pager == nil then
    vim.iter(hunks):each(function(hunk)
      insert(res, vim.list_slice(lines, hunk.diff_from + 1, hunk.diff_to))
    end)
    return res, mappings
  end

  local jobs = {}
  vim.iter(hunks):each(function(hunk)
    local header = lines[hunk.diff_from]
    local content = vim.list_slice(lines, hunk.diff_from + 1, hunk.diff_to)

    local job = vim.system(config.values.log_pager, { stdin = true })
    for _, part in ipairs { diff_header, { header }, content } do
      for _, line in ipairs(part) do
        job:write(line .. "\n")
      end
    end
    job:write()
    insert(jobs, { job = job, hunk_lines = content })
  end)

  vim.iter(jobs):each(function(item)
    local content = vim.split(item.job:wait().stdout, "\n")
    insert(res, content)
    insert(mappings, build_pager_line_mapping(content, item.hunk_lines))
  end)

  return res, mappings
end

---@param raw_diff string[]
---@param raw_stats string[]
---@return Diff
local function parse_diff(raw_diff, raw_stats)
  local header, start_idx = build_diff_header(raw_diff)
  local lines = build_lines(raw_diff, start_idx)
  local hunks = build_hunks(lines)
  local pager_contents, pager_line_mappings = build_pager_contents(header, lines, hunks)
  local kind, info = build_kind(header)
  local file = build_file(header, kind)
  local stats = parse_diff_stats(raw_stats or {})

  for i, hunk in ipairs(hunks) do
    hunk.file = file
    hunk.pager_line_mapping = pager_line_mappings[i]
    if pager_contents[i] and pager_line_mappings[i] then
      -- `hunk.length` is the offset of the last content line from the hunk
      -- header (= number of content rows). Mirror that for the rendered
      -- output so consumers can derive `hunk.last` the same way.
      hunk.pager_length = #pager_contents[i]
    end
  end

  return { ---@type Diff
    kind = kind,
    lines = lines,
    file = file,
    info = info,
    stats = stats,
    hunks = hunks,
    pager_contents = pager_contents,
  }
end

local function build_metatable(f, raw_output_fn)
  setmetatable(f, {
    __index = function(self, method)
      if method == "diff" then
        self.diff = a.util.block_on(function()
          logger.debug("[DIFF] Loading diff for: " .. f.name)
          return parse_diff(unpack(raw_output_fn()))
        end)

        return self.diff
      end
    end,
  })
end

-- Doing a git-diff with untracked files will exit(1) if a difference is observed, which we can ignore.
---@param name string
---@return fun(): table
local function raw_untracked(name)
  return function()
    local diff = git.cli.diff.no_ext_diff.no_index
      .files("/dev/null", name)
      .call({ hidden = true, ignore_error = true }).stdout
    local stats = {}

    return { diff, stats }
  end
end

---@param name string
---@return fun(): table
local function raw_unstaged(name)
  return function()
    local diff = git.cli.diff.no_ext_diff.files(name).call({ hidden = true }).stdout
    local stats = git.cli.diff.no_ext_diff.shortstat.files(name).call({ hidden = true }).stdout

    return { diff, stats }
  end
end

---@param name string
---@return fun(): table
local function raw_staged_unmerged(name)
  return function()
    local diff = git.cli.diff.no_ext_diff.files(name).call({ hidden = true }).stdout
    local stats = git.cli.diff.no_ext_diff.shortstat.files(name).call({ hidden = true }).stdout

    return { diff, stats }
  end
end

---@param name string
---@return fun(): table
local function raw_staged(name)
  return function()
    local diff = git.cli.diff.no_ext_diff.cached.files(name).call({ hidden = true }).stdout
    local stats = git.cli.diff.no_ext_diff.cached.shortstat.files(name).call({ hidden = true }).stdout

    return { diff, stats }
  end
end

---@param name string
---@return fun(): table
local function raw_staged_renamed(name, original)
  return function()
    local diff = git.cli.diff.no_ext_diff.cached.files(name, original).call({ hidden = true }).stdout
    local stats =
      git.cli.diff.no_ext_diff.cached.shortstat.files(name, original).call({ hidden = true }).stdout

    return { diff, stats }
  end
end

---@param section string
---@param file StatusItem
local function build(section, file)
  if section == "untracked" then
    build_metatable(file, raw_untracked(file.name))
  elseif section == "unstaged" then
    build_metatable(file, raw_unstaged(file.name))
  elseif section == "staged" and file.mode == "R" then
    build_metatable(file, raw_staged_renamed(file.name, file.original_name))
  elseif section == "staged" and file.mode:match("^[UAD][UAD]") then
    build_metatable(file, raw_staged_unmerged(file.name))
  elseif section == "staged" then
    build_metatable(file, raw_staged(file.name))
  else
    error("Unknown section: " .. vim.inspect(section))
  end
end

---@return DiffStagedStats
local function staged_stats()
  local raw = git.cli.diff.no_ext_diff.cached.stat.call({ hidden = true }).stdout
  local files = {}
  local summary

  local idx = 1
  local function advance()
    idx = idx + 1
  end

  local function peek()
    return raw[idx]
  end

  while true do
    local line = peek()
    if not line then
      break
    end

    if line:match("^ %d+ file[s ]+changed,") then
      summary = vim.trim(line)
      break
    else
      local file = { ---@type DiffStagedStatsFile
        path = vim.trim(line:match("^ ([^ ]+)")),
        changes = line:match("|%s+(%d+)"),
        insertions = line:match("|%s+%d+ (%+*)"),
        deletions = line:match("|%s+%d+ %+*(%-*)$"),
      }

      insert(files, file)
      advance()
    end
  end

  return {
    summary = summary,
    files = files,
  }
end

return { ---@type NeogitGitDiff
  parse = parse_diff,
  staged_stats = staged_stats,
  build = build,
  build_pager_line_mapping = build_pager_line_mapping,
}
