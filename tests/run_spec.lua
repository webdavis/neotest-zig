-- The command a run is built from, and the verdict each position comes back
-- with. Nothing here starts a process: the run's output is the fixture, because
-- what is under test is the adapter's reading of it.

local adapter = require("neotest-zig")

--- A stand-in for the part of `neotest.Tree` the adapter uses: `data()` on the
--- node handed over, and `iter_nodes()` over the file and its tests.
local function tree_of(file, tests)
  local nodes = { { data = file } }
  for _, test in ipairs(tests) do
    nodes[#nodes + 1] = { data = test }
  end
  return {
    data = function()
      return file
    end,
    iter_nodes = function()
      local index = 0
      return function()
        index = index + 1
        local node = nodes[index]
        return node and index,
          node and {
            data = function()
              return node.data
            end,
          }
      end
    end,
  }
end

local function file_position(path)
  return { id = path, type = "file", name = "t.zig", path = path }
end

local function test_position(path, tail, name)
  return { id = path .. "::" .. tail, type = "test", name = name, path = path }
end

local function report_holding(text)
  local path = vim.fn.tempname()
  local handle = assert(io.open(path, "w"))
  handle:write(text)
  handle:close()
  return path
end

--- `results` against a report written to disk, as the run would have left it.
local function results_for(path, tests, report_text)
  local tree = tree_of(file_position(path), tests)
  local spec = { context = { report = report_holding(report_text), path = path } }
  return adapter.results(spec, { output = "/dev/null" }, tree)
end

return {
  ["a file run is one zig test process, piped so the runner writes plain lines"] = function()
    local path = "/scratch/t.zig"
    local spec = adapter.build_spec({ tree = tree_of(file_position(path), {}) })
    assert(spec, "a file run built no spec")
    assert(spec.command[1] == "sh", "the run does not go through a shell: " .. spec.command[1])
    assert(
      spec.command[3]:find("| tee", 1, true),
      "the run is not piped, so a pty would hide every passing test: " .. spec.command[3]
    )
    assert(vim.list_contains(spec.command, "test") and vim.list_contains(spec.command, path), "wrong zig command")
    assert(not vim.list_contains(spec.command, "--test-filter"), "a whole-file run was filtered")
    assert(spec.env.NEOTEST_ZIG_REPORT == spec.context.report, "the report path did not reach the shell")
  end,

  ["a single test run selects it by the tail its name is reported under"] = function()
    local path = "/scratch/t.zig"
    local position = test_position(path, "test.adds two numbers", "adds two numbers")
    local spec = adapter.build_spec({ tree = tree_of(position, {}) })
    local filter
    for index, argument in ipairs(spec.command) do
      if argument == "--test-filter" then
        filter = spec.command[index + 1]
      end
    end
    assert(filter == "test.adds two numbers", "wrong filter: " .. tostring(filter))
  end,

  ["a directory is left to neotest, which asks for each file in turn"] = function()
    local spec = adapter.build_spec({ tree = tree_of({ id = "/scratch", type = "dir", path = "/scratch" }, {}) })
    assert(spec == nil, "a directory built its own zig test command")
  end,

  ["each position takes its own verdict, and a failure carries the line to jump to"] = function()
    local path = "/scratch/t.zig"
    local results = results_for(
      path,
      {
        test_position(path, "test.adds two numbers", "adds two numbers"),
        test_position(path, "test.deliberately fails", "deliberately fails"),
      },
      table.concat({
        "1/2 t.test.adds two numbers...OK",
        "2/2 t.test.deliberately fails...expected 5, found 3",
        "FAIL (TestExpectedEqual)",
        "/scratch/t.zig:8:5: 0x1010d196f in test.deliberately fails (test)",
        "1 passed; 0 skipped; 1 failed.",
        "",
      }, "\n")
    )

    local passed = results[path .. "::test.adds two numbers"]
    assert(passed and passed.status == "passed", "the passing test came back " .. vim.inspect(passed))
    local failed = results[path .. "::test.deliberately fails"]
    assert(failed and failed.status == "failed", "the failing test came back " .. vim.inspect(failed))
    assert(failed.errors[1].line == 7, "the jump is not on the test's own frame: " .. vim.inspect(failed.errors))
  end,

  ["a run that built nothing fails the position that was asked for"] = function()
    -- Returning no results would leave the tree looking untouched, which reads
    -- as "nothing was wrong" for a file that does not compile.
    local path = "/scratch/t.zig"
    local results =
      results_for(path, { test_position(path, "test.one", "one") }, "t.zig:3:1: error: expected type expression\n")
    assert(results[path], "the file position was not failed")
    assert(results[path].status == "failed", "a build failure was not a failure")
    assert(results[path].output == "/dev/null", "the compiler's own diagnostics were not attached")
  end,
}
