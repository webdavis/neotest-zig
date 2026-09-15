-- Everything neotest-zig knows about Zig's shapes, as pure functions over
-- strings and tables. No file system, no jobs, no neotest and no tree-sitter:
-- `init.lua` owns those, so every rule below is testable by `tests/run.lua`
-- under a bare `nvim --headless --clean -l`, with no plugin installed.
--
-- Output fixtures were measured against Zig 0.16.0's bundled test runner.

local M = {}

M.extension = ".zig"

---@param path string
---@return boolean
function M.has_zig_extension(path)
  return #path > #M.extension and path:sub(-#M.extension) == M.extension
end

-- Any `.zig` file may hold tests, so the extension alone would put every source
-- file in a project into neotest's summary. This is the cheap pre-filter that
-- keeps the plain ones out: `test` opening a line, followed by the whitespace,
-- quote or brace that the three declaration forms put there. A comment or a
-- multiline string shaped like one gets through, and `discover_positions` then
-- finds nothing in it, which is the same harmless outcome as a test file whose
-- tests were all deleted.
local TEST_LINE = '^%s*test[%s{"]'

---@param lines string[]
---@return boolean
function M.declares_a_test(lines)
  for _, line in ipairs(lines) do
    if line:match(TEST_LINE) then
      return true
    end
  end
  return false
end

---The tail of the name Zig's test runner reports a declaration under, which is
---the only handle a report line carries back to a position.
---
---Measured on 0.16.0, where the runner prints the fully qualified name as
---`<module>.<tail>` and spells the three declaration forms differently:
---
---  test "adds two numbers" { }   ->  test.adds two numbers
---  test someDecl { }             ->  decltest.someDecl
---  test { }                      ->  test_0
---
---The anonymous form is numbered across the anonymous declarations ALONE, in
---source order, so a named test between two of them does not consume an index
---(measured: `test_0`, `test.named`, `test_1`).
---@param declarations { kind: "string"|"decl"|"anonymous", text: string? }[]
---@return { kind: string, text: string?, tail: string, name: string }[]
function M.qualify(declarations)
  local anonymous = 0
  for _, declaration in ipairs(declarations) do
    if declaration.kind == "string" then
      declaration.tail = "test." .. declaration.text
      declaration.name = declaration.text
    elseif declaration.kind == "decl" then
      declaration.tail = "decltest." .. declaration.text
      declaration.name = declaration.text
    else
      declaration.tail = ("test_%d"):format(anonymous)
      declaration.name = declaration.tail
      anonymous = anonymous + 1
    end
  end
  return declarations
end

---The nested list `neotest.Tree.from_list` parses: the file, then one child per
---test declaration. Ranges are 0-based and come from the declaration's own
---node, so "run nearest" from inside a body finds the test it is inside.
---
---Zig refuses two tests with the same name in one file at COMPILE time
---("error: duplicate test name"), so a tail is unique within a file and needs
---no ambiguity guard of the kind a runner that reports by title alone does.
---@param path string absolute path
---@param declarations { tail: string, name: string, start_row: integer, end_row: integer }[]
---@param line_count integer
---@return table[]
function M.positions(path, declarations, line_count)
  local list = {
    {
      id = path,
      type = "file",
      name = path:match("[^/]+$") or path,
      path = path,
      range = { 0, 0, line_count, 0 },
    },
  }
  for _, declaration in ipairs(declarations) do
    list[#list + 1] = {
      id = path .. "::" .. declaration.tail,
      type = "test",
      name = declaration.name,
      path = path,
      range = { declaration.start_row, 0, declaration.end_row + 1, 0 },
    }
  end
  return list
end

---The module name Zig reports a test under, which is the root source file's
---basename with `.zig` removed.
---@param path string
---@return string
function M.module_of(path)
  local basename = path:match("[^/]+$") or path
  return (basename:gsub("%" .. M.extension .. "$", ""))
end

-- A line the test runner prints to open a test's record. The name is matched
-- non-greedily, so a FAILURE MESSAGE holding `...` cannot be mistaken for the
-- separator; the cost is that a test whose NAME holds `...` is cut short there,
-- which is the rarer of the two.
local RECORD_START = "^%d+/%d+ (.-)%.%.%.(.*)$"

-- The runner's closing summary, in both of its spellings, plus the compiler's
-- own `error:` line after a failing run. Any of them ends the last record, so
-- the run-wide counters do not land in one test's message.
local SUMMARY = { "^%d+ passed;", "^All %d+ tests? passed", "^error: " }

local function ends_the_records(line)
  for _, pattern in ipairs(SUMMARY) do
    if line:match(pattern) then
      return true
    end
  end
  return false
end

---Zig's test runner output, split into one record per test that started.
---
---A record is the `N/M <name>...` line plus everything the runner and the test
---itself wrote before the next record or the summary. Tests write to the same
---stream, so the verdict token is NOT reliably the first thing after the
---separator: a test that prints puts its own output there first.
---@param report_text string|nil
---@param module string
---@return table<string, { status: string, message: string, line: integer|nil }>|nil
---@return string|nil error
function M.records(report_text, module)
  if not report_text or report_text:match("^%s*$") then
    return nil, "neotest-zig: the zig test run produced no output"
  end

  local records, current = {}, nil
  for _, line in ipairs(vim.split(report_text, "\n", { plain = true })) do
    local name, rest = line:match(RECORD_START)
    if name then
      current = { name = name, fragments = { rest } }
      records[#records + 1] = current
    elseif current then
      if ends_the_records(line) then
        current = nil
      else
        current.fragments[#current.fragments + 1] = line
      end
    end
  end

  if #records == 0 then
    -- No test ever started. A compile error is the usual reason, and the
    -- compiler's diagnostics are already in the output the caller attaches.
    return nil, "neotest-zig: zig ran no tests, so the file did not build"
  end

  local prefix = "^" .. module:gsub("%W", "%%%0") .. "%."
  local by_tail = {}
  for _, record in ipairs(records) do
    local tail = record.name:match(prefix .. "(.*)$")
    if tail then
      by_tail[tail] = M.verdict(record.fragments)
    end
  end
  return by_tail
end

---One record's verdict and message.
---
---`FAIL` wins over everything, because a test may print a line reading exactly
---`OK` before it fails. A leak report wins too: the runner prints `OK` for a
---test that leaked and only counts it at the end, so reading the token alone
---reports a run Zig failed as a pass. A record carrying no token at all is a
---test the runner never finished, which is a failure as well.
---@param fragments string[]
---@return { status: string, message: string, line: integer|nil }
function M.verdict(fragments)
  local status
  for _, fragment in ipairs(fragments) do
    if fragment:match("^FAIL%f[^%w]") then
      status = "failed"
      break
    elseif fragment == "SKIP" then
      status = status or "skipped"
    elseif fragment == "OK" then
      status = status or "passed"
    end
  end

  local message = vim.trim(table.concat(fragments, "\n"))
  if status == "passed" and message:find("leaked:", 1, true) then
    status = "failed"
    message = message
      .. "\n\nneotest-zig: the runner reported OK and then reported leaked memory, which Zig counts as a failing run."
  end
  return { status = status or "failed", message = message }
end

---The 1-based line in `path` a failure happened on, read out of the stack trace
---Zig prints under it. The test's own frame is the last one naming the file, so
---the last match is the one to jump to rather than the first, which is inside
---`std.testing`.
---@param message string
---@param path string
---@return integer|nil
function M.failing_line(message, path)
  local pattern = "^" .. path:gsub("%W", "%%%0") .. ":(%d+):%d+:"
  local line
  for _, fragment in ipairs(vim.split(message, "\n", { plain = true })) do
    local number = fragment:match(pattern)
    if number then
      line = tonumber(number)
    end
  end
  return line
end

return M
