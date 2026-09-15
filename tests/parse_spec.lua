-- The rules in parse.lua, against output measured from Zig 0.16.0's own test
-- runner. The fixtures below are verbatim captures, trimmed of their absolute
-- paths only where the path is not what is being measured.

local parse = require("neotest-zig.parse")

-- One passing test and one failing test in `t.zig`, captured with stderr on a
-- pipe (`zig test t.zig 2>&1 | tee`). The stack trace is what a jump reads.
local PASS_AND_FAIL = [[
1/2 t.test.adds two numbers...OK
2/2 t.test.deliberately fails...expected 5, found 3
FAIL (TestExpectedEqual)
/scratch/t.zig:8:5: 0x1010d196f in test.deliberately fails (test)
    try std.testing.expectEqual(@as(i32, 5), 1 + 2);
    ^
1 passed; 0 skipped; 1 failed.
error: the following test command failed with exit code 1:
/cache/test --seed=0x9eaa7f0f
]]

-- A skip, a test that leaked and was still reported OK, and a test that printed
-- before it failed. Captured from `forms3.zig`.
local SKIP_LEAK_AND_PRINT = [[
1/3 forms3.test.skipped...SKIP
2/3 forms3.test.leaky...OK
[DebugAllocator] (err): memory address 0x1027e0000 leaked:
/scratch/forms3.zig:4:47: 0x102689a87 in test.leaky (test)
    const p = try std.testing.allocator.create(u32);
                                              ^
3/3 forms3.test.prints...hello from the test
FAIL (TestUnexpectedResult)
/scratch/forms3.zig:9:5: 0x1026898cb in test.prints (test)
    try std.testing.expect(1 == 2);
    ^
1 passed; 1 skipped; 1 failed.
1 errors were logged.
1 tests leaked memory.
]]

return {
  ["a .zig path is a candidate and another extension is not"] = function()
    assert(parse.has_zig_extension("/p/root.zig"), "a .zig file was refused")
    assert(not parse.has_zig_extension("/p/root.zon"), "a .zon file was accepted")
    assert(not parse.has_zig_extension(".zig"), "a bare extension with no name was accepted")
  end,

  ["a Zig file is a test file only when it opens a test declaration"] = function()
    assert(parse.declares_a_test({ 'test "named" {' }), "the quoted form was missed")
    assert(parse.declares_a_test({ "test someDecl {" }), "the declaration form was missed")
    assert(parse.declares_a_test({ "test {" }), "the anonymous form was missed")
    assert(parse.declares_a_test({ "    test {" }), "an indented declaration was missed")
    assert(not parse.declares_a_test({ "const testing = std.testing;" }), "an identifier read as a declaration")
    assert(not parse.declares_a_test({ "fn testable() void {}" }), "a function read as a declaration")
  end,

  ["the anonymous form is numbered across the anonymous declarations alone"] = function()
    -- Measured: `test {}`, `test "named" {}`, `test {}` report as `test_0`,
    -- `test.named` and `test_1`, so a named test between two anonymous ones
    -- does not consume an index.
    local qualified = parse.qualify({
      { kind = "anonymous" },
      { kind = "string", text = "named" },
      { kind = "anonymous" },
      { kind = "decl", text = "someDecl" },
    })
    local tails = {}
    for _, declaration in ipairs(qualified) do
      tails[#tails + 1] = declaration.tail
    end
    assert(
      table.concat(tails, "|") == "test_0|test.named|test_1|decltest.someDecl",
      "wrong tails: " .. table.concat(tails, "|")
    )
  end,

  ["positions are the file and one node per declaration, with 0-based ranges"] = function()
    local list = parse.positions(
      "/p/t.zig",
      parse.qualify({
        { kind = "string", text = "one", start_row = 2, end_row = 4 },
      }),
      9
    )
    assert(#list == 2, "expected a file and one test, got " .. #list)
    assert(list[1].type == "file" and list[1].id == "/p/t.zig", "the file position is wrong")
    assert(list[2].id == "/p/t.zig::test.one", "the test id is wrong: " .. list[2].id)
    assert(list[2].name == "one", "the test name is wrong: " .. list[2].name)
    assert(vim.deep_equal(list[2].range, { 2, 0, 5, 0 }), "the test range is wrong: " .. vim.inspect(list[2].range))
  end,

  ["the module a test is reported under is the root source file's basename"] = function()
    assert(parse.module_of("/p/src/root.zig") == "root", "wrong module")
    assert(parse.module_of("/p/my.zig.zig") == "my.zig", "only the trailing extension comes off")
  end,

  ["a pass and a failure are read off the runner's own output"] = function()
    local verdicts = assert(parse.records(PASS_AND_FAIL, "t"))
    assert(verdicts["test.adds two numbers"].status == "passed", "the passing test was not read as passed")
    local failed = verdicts["test.deliberately fails"]
    assert(failed.status == "failed", "the failing test was read as " .. failed.status)
    assert(failed.message:find("expected 5, found 3", 1, true), "the assertion message was lost")
    assert(not failed.message:find("1 passed;", 1, true), "the run's summary landed in one test's message")
  end,

  ["a jump lands on the test's own frame, not the one inside std.testing"] = function()
    local verdicts = assert(parse.records(PASS_AND_FAIL, "t"))
    local message = verdicts["test.deliberately fails"].message
    assert(parse.failing_line(message, "/scratch/t.zig") == 8, "wrong failing line")
    assert(parse.failing_line(message, "/scratch/other.zig") == nil, "a frame in another file was claimed")
  end,

  ["a skip is a skip and a test that printed before failing still fails"] = function()
    local verdicts = assert(parse.records(SKIP_LEAK_AND_PRINT, "forms3"))
    assert(verdicts["test.skipped"].status == "skipped", "SKIP was not read as skipped")
    local printed = verdicts["test.prints"]
    assert(printed.status == "failed", "a test that printed first was read as " .. printed.status)
    assert(printed.message:find("hello from the test", 1, true), "the test's own output was lost")
  end,

  ["a test the runner reported OK and then reported leaking is failed"] = function()
    -- The worst outcome this adapter can produce is a failing run shown green.
    -- Zig prints OK for a leaking test and only counts it in the summary, so
    -- reading the token alone reports a run Zig failed as a pass.
    local verdicts = assert(parse.records(SKIP_LEAK_AND_PRINT, "forms3"))
    assert(verdicts["test.leaky"].status == "failed", "a leaking test was reported as passing")
  end,

  ["a line reading exactly OK printed by a failing test does not beat FAIL"] = function()
    local verdicts = assert(parse.records("1/1 t.test.liar...OK\nFAIL (TestUnexpectedResult)\n", "t"))
    assert(verdicts["test.liar"].status == "failed", "a printed OK outranked the runner's FAIL")
  end,

  ["a record with no verdict token at all is a failure"] = function()
    -- A test that panicked or was killed: the runner never got to print one.
    local verdicts = assert(parse.records("1/1 t.test.gone...\nthread panic: reached unreachable code\n", "t"))
    assert(verdicts["test.gone"].status == "failed", "an unfinished test was not failed")
  end,

  ["tests reported under another module are not attributed to this file"] = function()
    -- `refAllDecls` pulls an imported file's tests into the same run, and their
    -- names carry that file's module. None of them is a position in this file.
    local verdicts = assert(parse.records("1/1 other.test.theirs...OK\n1/1 t.test.ours...OK\n", "t"))
    assert(verdicts["test.ours"], "this file's own test was dropped")
    assert(verdicts["test.theirs"] == nil, "another module's test was attributed here")
  end,

  ["a run that started no test reports why rather than an empty verdict set"] = function()
    -- A compile error is the usual reason, and an empty table would read as
    -- "every test is fine".
    local verdicts, failure = parse.records("t.zig:3:1: error: expected type expression\n", "t")
    assert(verdicts == nil, "a build failure produced verdicts")
    assert(failure and failure:find("did not build", 1, true), "the reason is unhelpful: " .. tostring(failure))

    local empty, no_output = parse.records("", "t")
    assert(empty == nil and no_output, "empty output produced verdicts")
  end,
}
