# neotest-zig

A [neotest](https://github.com/nvim-neotest/neotest) adapter for Zig's built-in `test` declarations.

It owns no Zig code. Tests run through `zig test`, and the results are read from the output of the
test runner Zig itself ships, so a standard-library rename does not break the adapter.

## Requirements

- Neovim 0.10 or newer, which is where `vim.fs.root` arrived. Developed on 0.12.5.
- [neotest](https://github.com/nvim-neotest/neotest).
- `zig` on your `PATH`. Developed and measured against Zig 0.16.0.
- The `zig` tree-sitter parser, which is what discovery reads.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim), as a dependency of neotest:

```lua
{
  "nvim-neotest/neotest",
  dependencies = {
    "nvim-neotest/nvim-nio",
    "webdavis/neotest-zig",
  },
  config = function()
    require("neotest").setup({
      adapters = {
        require("neotest-zig"),
      },
    })
  end,
}
```

## Configure

There is nothing to configure. The adapter is a plain table with no `setup` function and no
options: `require` it and put it in the list.

## Which files it finds

A test file is a `.zig` file that opens a `test` declaration. All three of Zig's forms are
discovered, and each is reported under the name Zig's runner gives it:

```zig
test "adds two numbers" {}  // reported as `test.adds two numbers`
test someDecl {}            // reported as `decltest.someDecl`
test {}                     // reported as `test_0`, numbered across the anonymous ones
```

## Which directories it claims

A directory belongs to this adapter when the nearest ancestor holding a `build.zig`, a
`build.zig.zon` or a `.git` either:

- holds one of the two build manifests, which is an explicit declaration of a Zig project and is
  taken at its word, with or without any source; or
- has at least one `.zig` file reachable inside it.

The second rule is there because `.git` sits at the top of every repository. neotest hands a
whole-directory run to the single adapter that claimed the directory, so claiming on the marker
alone would send a project with no Zig in it to `zig test`.

Discovery prunes `.git`, `.zig-cache`, `zig-out` and `node_modules`.

## How a run is built

One `zig test <file>` process per file. Running a single test passes `--test-filter` with the name
that test is reported under. The filter is a substring match, so a sibling whose name contains the
selected one runs too; every test the output names gets its own verdict, so a sibling dragged in
this way is reported correctly rather than discarded.

The run is piped through `tee`. Zig's test runner decides its output format on whether stderr is a
terminal, and neotest runs every command under a pty: on a terminal the runner draws a progress bar
and prints nothing for a test that passed. The pipe is what makes it emit one plain line per test.

A test that leaks memory is reported as failed. Zig prints `OK` for it and counts the leak only in
the closing summary, so reading the verdict token alone would show a run Zig failed as a pass.

Because each file is compiled as its own root source file, a test in a file that imports a module
declared in `build.zig` cannot be run this way. Put those tests in a file that stands alone, or run
`zig build test` yourself.

## Tests

Run the suite under a bare headless Neovim, with no plugins installed:

```sh
nvim --headless --clean -l tests/run.lua
```

Nothing in it starts a `zig` process: the fixtures are captured output from Zig 0.16.0's runner.
Pass a spec name to narrow the run, for example `nvim --headless --clean -l tests/run.lua
parse_spec`.

## License

MIT. See `LICENSE`.
