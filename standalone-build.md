# Standalone build plan for `escript_tool`

## Goal

Ship `escript_tool` as a single executable file that runs on a machine with **no
Erlang/OTP or Elixir installed**.

## Why the current escript cannot do this

An escript is a zip archive of compiled `.beam` files with a `#!/usr/bin/env escript`
shebang. It contains no virtual machine. The target machine must already have `erl`
on its `PATH`, and the installed ERTS version must be compatible with the BEAM files
inside the archive. There is no supported way to embed ERTS in an escript, so the
escript format itself is the limit, not the project configuration.

## Options considered

| Option | Standalone? | Cross-platform build? | Status | Verdict |
|---|---|---|---|---|
| `mix escript.build` (current) | No | n/a | Built in | Keep for local dev only |
| `mix release` tarball + ERTS | Yes, but a directory tree, not one file | No, must build on the target OS | Built in | Fallback if Burrito is unsuitable |
| **Burrito** (`burrito` on Hex) | **Yes, one file per target** | **Yes, from one machine** | Active, v1.6.0 (July 2026) | **Recommended** |
| Bakeware | Yes, one file | No | Unmaintained since 2021 | Rejected |
| Docker image | Yes | Yes | n/a | Rejected, requires Docker on the target |

## Recommendation: Mix release wrapped by Burrito

Burrito takes a normal Mix release, downloads a precompiled ERTS for each target
OS/CPU, bundles the release and ERTS into an xz-compressed payload, and wraps it in
a small Zig launcher. The result is one native executable per target. On first run
the launcher unpacks the payload into a per-user cache directory and executes it.
Later runs skip the unpack.

Burrito provides precompiled OTP from 25.3 onward for macOS, Linux and Windows. This
project runs on OTP 28 / Elixir 1.20.4, which is in range. Burrito picks the ERTS
version that matches the OTP you build with, so the OTP 28 patch release in use must
exist in Burrito's download index. If it does not, set `BURRITO_ERTS_PATH` to a local
ERTS for same-platform builds, or build with the nearest supported OTP patch.

### Tradeoffs to accept

- **Binary size.** Roughly 15 to 30 MB per target, since ERTS is inside.
- **First-run latency.** The one-time unpack takes a second or two. Later runs are
  near native release startup, which is still slower than a C binary.
- **Cache directory.** The unpacked payload lives in the user's data directory
  (`~/.local/share/.burrito` on Linux). The binary ships `maintenance uninstall`,
  `maintenance directory` and `maintenance meta` subcommands to manage it.
- **One file per platform.** There is no universal binary. Build a matrix.
- **NIFs.** This project has no native dependencies, so cross-compilation from one
  host works. If a NIF dependency is added later, each target must be built on its
  own OS, or the NIF must be precompiled for every target.
- **Entry point changes.** A release boots an OTP application. It never calls
  `EscriptTool.main/1`. The CLI needs an `Application` callback that reads the
  argument list and exits explicitly.

## Build machine prerequisites

Current state of this machine:

| Tool | Needed for | Installed? |
|---|---|---|
| Zig 0.15.2 | Launcher compilation, all targets | **No** |
| `xz` | Payload compression, all targets | Yes (`/usr/bin/xz`) |
| `7z` | Windows targets only | **No** |

Install Zig from https://ziglang.org/download/ as a tarball unpacked onto `PATH`.
Distro packages often lag and Burrito pins an exact version, so prefer the official
tarball. Install `p7zip-full` (Debian/Ubuntu) only if Windows binaries are wanted.

## Implementation steps

### 1. Add the dependency and release config

In `mix.exs`:

```elixir
def project do
  [
    app: :escript_tool,
    version: "0.1.0",
    elixir: "~> 1.20",
    start_permanent: Mix.env() == :prod,
    deps: deps(),
    escript: [main_module: EscriptTool],
    releases: releases()
  ]
end

def application do
  [
    extra_applications: [:logger],
    mod: {EscriptTool.Application, []}
  ]
end

defp releases do
  [
    escript_tool: [
      steps: [:assemble, &Burrito.wrap/1],
      burrito: [
        targets: [
          linux: [os: :linux, cpu: :x86_64],
          linux_arm: [os: :linux, cpu: :aarch64],
          macos: [os: :darwin, cpu: :x86_64],
          macos_silicon: [os: :darwin, cpu: :aarch64],
          windows: [os: :windows, cpu: :x86_64]
        ]
      ]
    ]
  ]
end

defp deps do
  [
    {:burrito, "~> 1.6"}
  ]
end
```

Trim the target list to what will actually be shipped. Each target adds build time
and an ERTS download.

### 2. Add an Application entry point

Create `lib/escript_tool/application.ex`:

```elixir
defmodule EscriptTool.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    args = Burrito.Util.Args.argv()
    code = EscriptTool.run(args)
    System.halt(code)
  end
end
```

Points to get right:

- **Halt explicitly.** Without `System.halt/1` the release stays alive as a daemon
  after `start/2` returns. `System.halt/1` flushes standard I/O before exiting.
- **`Burrito.Util.Args.argv/0` versus `System.argv/0`.** Inside a Burrito binary the
  real program arguments arrive through the launcher, not the VM's argv. The Burrito
  helper returns the right list in both the wrapped binary and a plain release.
- **No supervision tree.** Since the tool is short-lived there is nothing to
  supervise. Returning `{:ok, pid}` is never reached because the process halts first.

### 3. Refactor `EscriptTool` so both entry points share one code path

Keep `main/1` for the escript, but make it a thin wrapper:

```elixir
defmodule EscriptTool do
  @moduledoc "CLI entry points."

  @doc "Escript entry point."
  def main(args) do
    args |> run() |> System.halt()
  end

  @doc "Runs the CLI and returns a process exit code."
  @spec run([String.t()]) :: non_neg_integer()
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args, strict: [help: :boolean], aliases: [h: :help])

    cond do
      opts[:help] ->
        IO.puts("Usage: escript_tool [--help]")
        0

      invalid != [] ->
        IO.puts(:stderr, "Invalid options: #{inspect(invalid)}")
        2

      true ->
        IO.puts("Positional arguments: #{inspect(positional)}")
        0
    end
  end
end
```

Returning an exit code from `run/1` instead of calling `System.halt/1` inside it
keeps the function testable with ExUnit and `ExUnit.CaptureIO`.

### 4. Keep the escript build working

Adding `mod:` to `application/0` means the escript will also boot
`EscriptTool.Application` when `mix escript.build` output runs. That is fine because
`start/2` reads arguments and halts. To be safe, keep the `escript:` key so
`mix escript.build` still produces the dev binary, and verify both paths in step 6.

### 5. Build

```bash
mix deps.get
MIX_ENV=prod mix release
```

Binaries land in `burrito_out/`, one per configured target, named
`escript_tool_<target>`. To build a subset during development:

```bash
MIX_ENV=prod BURRITO_TARGET=linux mix release
```

Add `/burrito_out/` to `.gitignore`.

### 6. Verify

```bash
./burrito_out/escript_tool_linux --help
./burrito_out/escript_tool_linux a b c; echo "exit=$?"
./burrito_out/escript_tool_linux --bogus; echo "exit=$?"   # expect 2
./burrito_out/escript_tool_linux maintenance meta
```

Then copy the Linux binary into a clean container without Erlang to prove
independence:

```bash
docker run --rm -v "$PWD/burrito_out:/b" debian:bookworm-slim /b/escript_tool_linux --help
```

Also confirm the escript still builds and runs: `mix escript.build && ./escript_tool --help`.

### 7. Automate releases

Use a GitHub Actions workflow that:

1. Installs Erlang/Elixir via `erlef/setup-beam`, Zig 0.15.2 via `mlugg/setup-zig`
   or a direct download, and `xz`/`p7zip`.
2. Runs `MIX_ENV=prod mix release`.
3. Uploads `burrito_out/*` as release assets on a tag push.

Because this project has no NIFs, a single `ubuntu-latest` runner can build every
target. Switch to a per-OS matrix only if native dependencies appear.

## Hex packages

| Package | Purpose | Include? |
|---|---|---|
| `burrito` `~> 1.6` | Wraps the release into standalone binaries | **Yes** |
| `optimus` | Declarative CLI parsing with subcommands, auto `--help`, typed args | Optional. Worth it once the CLI grows past a couple of flags |
| `owl` | Colours, progress bars, tables, prompts for terminal output | Optional, when richer output is wanted |
| `bakeware` | Older single-binary packager | No, unmaintained |

`OptionParser` from the standard library is enough for the current skeleton.

## Fallback if Burrito is not acceptable

Plain `mix release` with `include_erts: true` (the default) produces a self-contained
directory under `_build/prod/rel/escript_tool/`. Tar it up and ship the tarball with a
one-line wrapper script that calls `bin/escript_tool eval` or a custom start command.
This avoids Zig and the first-run unpack, at the cost of distributing a directory
instead of a single file, and of building on each target OS separately.

## Order of work

1. Install Zig 0.15.2 on the build machine.
2. Apply the `mix.exs`, `application.ex` and `escript_tool.ex` changes above.
3. Build the Linux target only with `BURRITO_TARGET=linux` and run the checks in step 6.
4. Expand to the full target list and add the CI workflow.
