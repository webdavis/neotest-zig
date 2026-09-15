-- neotest-zig: a neotest adapter for Zig's built-in `test` declarations.
--
-- It owns no Zig code. Upstream `lawrence-laz/neotest-zig` ships its own
-- Zig-side test runner, and that is exactly what stopped working: the runner is
-- written against a `std` shape that 0.15 and 0.16 changed, so `zig test` no
-- longer compiles it. This adapter reads the output of the runner Zig itself
-- ships, so a standard-library rename is the compiler team's problem rather
-- than this repository's.
--
-- Discovery and output rules live in `parse.lua` as pure functions, verified by
-- `tests/` under a bare headless Neovim. This file owns the neotest interface,
-- tree-sitter, the file system and the command.

local parse = require("neotest-zig.parse")

---@type neotest.Adapter
local adapter = { name = "neotest-zig" }

-- The report file the run tees its output into, named in the environment rather
-- than interpolated into the shell script below.
local REPORT_VARIABLE = "NEOTEST_ZIG_REPORT"

-- Zig's test runner decides its output format on whether stderr is a terminal,
-- and neotest runs every command under a pty. On a terminal the runner draws a
-- progress bar and prints NOTHING for a test that passed, so the `...OK` lines
-- this adapter reads are overwritten before they can be captured (measured on
-- 0.16.0: a two-test run under a pty showed only the failing test). Piping the
-- run through `tee` puts a pipe on the far end of zig's stderr, which is what
-- makes it emit one plain line per test, and keeps the live output neotest
-- displays. `exec` replaces the pipeline's own subshell so no extra process
-- outlives the run.
local TEE_THROUGH_A_PIPE = ('exec "$@" 2>&1 | tee -- "$%s"'):format(REPORT_VARIABLE)

---@param name string
---@return boolean
function adapter.filter_dir(name)
  -- `.zig-cache` and `zig-out` are the build's own output trees: both hold
  -- generated `.zig` files, and neither holds a test anybody wrote.
  return name ~= ".git" and name ~= ".zig-cache" and name ~= "zig-out" and name ~= "node_modules"
end

---Whether any Zig file is reachable below `root`.
---
---`vim.fs.dir` rather than `vim.fs.find`: find's downward walk cannot prune a
---directory, so on a root holding no Zig it would read `.git` and
---`node_modules` in full. `vim.fs.dir` is a lazy iterator, so the first match
---ends the walk. `skip` is handed the path relative to `root`, so the
---comparison is against the last component.
---@param root string
---@return boolean
local function holds_zig_source(root)
  for name, kind in
    vim.fs.dir(root, {
      depth = math.huge,
      skip = function(relative)
        return adapter.filter_dir(vim.fs.basename(relative))
      end,
    })
  do
    if kind == "file" and parse.has_zig_extension(name) then
      return true
    end
  end
  return false
end

---@param dir string
---@return string|nil
function adapter.root(dir)
  local root = vim.fs.root(dir, { "build.zig", "build.zig.zon", ".git" })
  -- A build manifest is somebody declaring a Zig project and is taken at its
  -- word. A bare `.git` is not: it marks every repository there is, and neotest
  -- hands a whole-directory run to the single adapter that claimed the
  -- directory, so claiming on the marker alone would run "all tests" through
  -- `zig test` in projects holding no Zig at all.
  if not root or vim.uv.fs_stat(root .. "/build.zig") or vim.uv.fs_stat(root .. "/build.zig.zon") then
    return root
  end
  return holds_zig_source(root) and root or nil
end

---@param file_path string
---@return boolean
function adapter.is_test_file(file_path)
  if not parse.has_zig_extension(file_path) or vim.fn.filereadable(file_path) ~= 1 then
    return false
  end
  return parse.declares_a_test(vim.fn.readfile(file_path))
end

-- Zig's grammar calls the node `test_declaration`. Upstream's closed issue 32
-- names it `TestDecl`, which was the node type of an older grammar; verified
-- against the installed parser rather than taken from either.
local TEST_QUERY = "(test_declaration) @test"

---Every test declaration in a file, in source order, read off the parse tree.
---
---Tree-sitter rather than a line pattern because Zig has multiline strings and
---comments, and a line inside either can be shaped exactly like a declaration.
---Returns nil when no `zig` parser is installed, which is the one thing this
---cannot work around.
---@param source string
---@return { kind: string, text: string?, start_row: integer, end_row: integer }[]|nil
local function declarations_in(source)
  local ok, parser = pcall(vim.treesitter.get_string_parser, source, "zig")
  if not ok or not parser then
    return nil
  end
  local tree = parser:parse()[1]
  if not tree then
    return nil
  end
  local query = vim.treesitter.query.parse("zig", TEST_QUERY)
  local found = {}
  for _, node in query:iter_captures(tree:root(), source) do
    local kind, text = "anonymous", nil
    for child in node:iter_children() do
      -- The name is the node between the `test` keyword and the block: a
      -- `string` for the quoted form, an `identifier` for the declaration form,
      -- and absent for the anonymous one.
      if child:type() == "string" then
        kind = "string"
        text = vim.treesitter.get_node_text(child, source):sub(2, -2)
      elseif child:type() == "identifier" then
        kind = "decl"
        text = vim.treesitter.get_node_text(child, source)
      end
    end
    local start_row, _, end_row = node:range()
    found[#found + 1] = { kind = kind, text = text, start_row = start_row, end_row = end_row }
  end
  return parse.qualify(found)
end

---@param file_path string
---@return neotest.Tree|nil
function adapter.discover_positions(file_path)
  local lines = vim.fn.readfile(file_path)
  local declarations = declarations_in(table.concat(lines, "\n"))
  if not declarations then
    return nil
  end
  return require("neotest.types").Tree.from_list(parse.positions(file_path, declarations, #lines), function(position)
    return position.id
  end)
end

---@param args neotest.RunArgs
---@return neotest.RunSpec|nil
function adapter.build_spec(args)
  local position = args.tree:data()
  -- A directory is left to neotest, which then asks for each file below it in
  -- turn. One `zig test` per root source file is the unit Zig itself offers.
  if position.type ~= "file" and position.type ~= "test" then
    return nil
  end

  local report = vim.fn.tempname()
  local command = { "sh", "-c", TEE_THROUGH_A_PIPE, "sh", "zig", "test", position.path }

  if position.type == "test" then
    -- `--test-filter` is a substring match against the FULLY QUALIFIED name, so
    -- the tail alone selects the test. A sibling whose name contains this one's
    -- runs too, which costs nothing worth avoiding: the compile dominates the
    -- run, and `results` reports every test the output names, so a dragged-in
    -- sibling gets its own true verdict rather than being silently discarded.
    vim.list_extend(command, { "--test-filter", position.id:match("::(.*)$") })
  end
  vim.list_extend(command, args.extra_args or {})

  return {
    command = command,
    cwd = adapter.root(position.path) or vim.fs.dirname(position.path),
    context = { report = report, path = position.path },
    env = { [REPORT_VARIABLE] = report },
  }
end

---@param path string|nil
---@return string|nil
local function read_file(path)
  if not path or vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  return table.concat(vim.fn.readfile(path, "b"), "\n")
end

---A file holding one test's own slice of the run's output.
---@param message string
---@return string
local function write_output(message)
  local path = vim.fn.tempname()
  vim.fn.writefile(vim.split(message, "\n"), path)
  return path
end

---@param spec neotest.RunSpec
---@param result neotest.StrategyResult
---@param tree neotest.Tree
---@return table<string, neotest.Result>
function adapter.results(spec, result, tree)
  local path = spec.context and spec.context.path or tree:data().path
  local verdicts, failure = parse.records(read_file(spec.context and spec.context.report), parse.module_of(path))
  if not verdicts then
    -- Nothing ran. Returning no results would read as "the tree was not
    -- touched"; failing what was asked for, with the run's own output attached,
    -- says what happened and puts the compiler's diagnostics one key away.
    return {
      [tree:data().id] = { status = "failed", short = failure, output = result.output },
    }
  end

  local results = {}
  for _, node in tree:iter_nodes() do
    local data = node:data()
    local verdict = data.type == "test" and verdicts[data.id:match("::(.*)$")]
    if verdict then
      local entry = { status = verdict.status, output = result.output }
      -- A test that passed or skipped quietly has a message of nothing but its
      -- own verdict token, which is no use in an output window, so it keeps the
      -- whole run's output the way neotest would have shown it anyway.
      if verdict.message ~= "OK" and verdict.message ~= "SKIP" then
        entry.short = verdict.message
        entry.output = write_output(verdict.message)
      end
      if verdict.status == "failed" then
        local line = parse.failing_line(verdict.message, data.path)
        entry.errors = { { message = verdict.message, line = line and line - 1 or nil } }
      end
      results[data.id] = entry
    end
  end
  return results
end

return adapter
