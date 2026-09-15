-- Headless Lua test runner for neotest-zig, the same shape as the Neovim
-- config's `tests/run.lua`.
--
-- Usage: nvim --headless --clean -l tests/run.lua [<name>_spec]
--
-- `--clean` keeps every plugin out, neotest included, which is the point: the
-- rules under test are the pure ones in `parse.lua`, so they must hold with
-- no plugins installed. Nothing here shells out to `zig`.
-- A spec file returns a table of
-- `["what it does"] = function() ... end` cases and asserts with plain
-- `assert`. No plenary, no busted.

local tests_dir = arg[0]:match("(.*)/") or "."
local project_root = tests_dir .. "/.."
local only = arg[1]

package.path = ("%s/lua/?.lua;%s/lua/?/init.lua;%s"):format(project_root, project_root, package.path)

local spec_files
if only then
  spec_files = { ("%s/%s.lua"):format(tests_dir, only) }
else
  spec_files = vim.fn.glob(tests_dir .. "/*_spec.lua", false, true)
end

-- A run that found nothing to do would otherwise exit 0 and read as a pass.
if #spec_files == 0 then
  error("no spec files matched under " .. tests_dir)
end

local failures = 0

-- Not `print`: under `nvim -l` that routes through the message system, which
-- swallows the newline after a line exactly `columns` wide and leaves the final
-- line unterminated. `io.write` goes straight to stdout.
local function report(line)
  io.write(line, "\n")
end

for _, path in ipairs(spec_files) do
  local spec = path:match("([^/]+)%.lua$")
  local cases = dofile(path)

  -- Sorted, so a run reports its cases in the same order every time.
  local names = {}
  for name in pairs(cases) do
    table.insert(names, name)
  end
  table.sort(names)

  for _, name in ipairs(names) do
    local ok, err = pcall(cases[name])
    if ok then
      report(("ok %s: %s"):format(spec, name))
    else
      failures = failures + 1
      report(("FAIL %s: %s: %s"):format(spec, name, err))
    end
  end
end

os.exit(failures == 0 and 0 or 1)
