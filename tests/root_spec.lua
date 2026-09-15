-- Which directories neotest-zig claims as its own, and which files it offers.
--
-- A marker alone is not enough. `.git` sits at the top of every repository in
-- existence, so claiming on the marker would attach this adapter to all of
-- them, and neotest hands a directory run to the one adapter that claimed the
-- directory: a repository with no Zig in it would run its "all tests" through
-- `zig test` and find nothing.
--
-- Real directories under `vim.fn.tempname()` rather than a stubbed file system:
-- the rule is a question about what is on disk, and a fake would only prove the
-- fake agrees with itself.

local adapter = require("neotest-zig")

local function tree(layout)
  local root = assert(vim.fn.tempname())
  vim.fn.mkdir(root, "p")
  root = vim.uv.fs_realpath(root) or root
  for relative, contents in pairs(layout) do
    local path = root .. "/" .. relative
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local handle = assert(io.open(path, "w"), "could not write " .. path)
    handle:write(contents)
    handle:close()
  end
  return root
end

return {
  ["a project declaring a build manifest is claimed with no source present"] = function()
    local root = tree({ ["build.zig.zon"] = ".{}\n" })
    assert(adapter.root(root) == root, "expected the project root, got " .. tostring(adapter.root(root)))
  end,

  ["a repository holding Zig source is claimed"] = function()
    local root = tree({ [".git/HEAD"] = "ref: refs/heads/main\n", ["src/root.zig"] = "" })
    assert(adapter.root(root) == root, "expected the repository root, got " .. tostring(adapter.root(root)))
  end,

  ["a repository holding no Zig source is not claimed"] = function()
    local root = tree({ [".git/HEAD"] = "ref: refs/heads/main\n", ["src/index.js"] = "" })
    assert(adapter.root(root) == nil, "expected nil, got " .. tostring(adapter.root(root)))
  end,

  ["Zig source only inside the build's own output tree does not claim the repository"] = function()
    -- `filter_dir` already refuses these during discovery, so a file neotest
    -- would never run must not be what attaches the adapter either.
    local root = tree({
      [".git/HEAD"] = "ref: refs/heads/main\n",
      [".zig-cache/o/deadbeef/generated.zig"] = "",
      ["zig-out/share/vendored.zig"] = "",
    })
    assert(adapter.root(root) == nil, "expected nil, got " .. tostring(adapter.root(root)))
  end,

  ["a directory under no marker at all is claimed by nobody"] = function()
    local root = tree({ ["root.zig"] = "" })
    assert(adapter.root(root) == nil, "expected nil, got " .. tostring(adapter.root(root)))
  end,

  ["only a Zig file that opens a test declaration is offered as a test file"] = function()
    local root = tree({
      ["with.zig"] = 'const std = @import("std");\ntest "one" {}\n',
      ["without.zig"] = "pub fn main() void {}\n",
      ["notzig.zon"] = 'test "one" {}\n',
    })
    assert(adapter.is_test_file(root .. "/with.zig"), "a file holding a test was refused")
    assert(not adapter.is_test_file(root .. "/without.zig"), "a plain source file was offered")
    assert(not adapter.is_test_file(root .. "/notzig.zon"), "a non-Zig file was offered")
    assert(not adapter.is_test_file(root .. "/absent.zig"), "a file that does not exist was offered")
  end,

  ["the build's own output trees are pruned from discovery"] = function()
    assert(not adapter.filter_dir(".zig-cache"), ".zig-cache is walked")
    assert(not adapter.filter_dir("zig-out"), "zig-out is walked")
    assert(adapter.filter_dir("src"), "src is pruned")
  end,
}
