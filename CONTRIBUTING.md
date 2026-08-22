# Contributing to Mox

Mox is an Apple-Silicon-only MLX runtime that ships a `mox` CLI, an
`mox-server` launchd daemon, and a SwiftUI `MoxGUI` front-end. Everything
below assumes that target.

## Development Setup

### Prerequisites

- Swift **6.2** or newer (the manifest's `swift-tools-version` is `6.2`; a
  Swift 6.0 toolchain refuses to load the package).
- macOS **15** or newer (the manifest declares `.macOS(.v15)`; v15 SDK
  features are used at runtime — Swift 6.2 `~` `os.OSAllocatedUnfairLock`,
  NIO 2.101, mlx-swift-lm 3.31).
- **Apple Silicon only.** The MLX framework does not build on Intel Macs
  and no product in this repository has an Intel code path. Rosetta does
  not help; the linker will fail at `MLX.metallib`.

### Building

```bash
git clone https://github.com/yourusername/mox.git
cd mox
swift build
swift run mox --help
```

### Testing

```bash
swift test
```

Tests use [swift-testing](https://github.com/swiftlang/swift-testing) via
the `Testing` package — `XCTest.framework` is not available on the
CommandLineTools SDK and `XCTestCase` will not compile.

## Project Structure

```
Sources/
├── MoxShared/             # Cross-module types (Sendable + Codable)
├── MoxCore/               # Model lifecycle, config, download, memory, MLX
│   ├── ConfigManager      # ~/.mox/config.json (actor + sync helpers)
│   ├── Downloader         # URLSession + Range + SHA-256
│   ├── MemoryGuard        # host_statistics64 → available memory
│   ├── ModelManager       # pull / list / delete (actor)
│   └── ModelRunner        # mlx-swift-lm inference (actor)
├── MoxServer/             # NIO HTTP server (OpenAI + Anthropic compatible)
├── MoxServerCLI/          # `mox-server` binary + launchd agent
├── MoxConvertCore/        # v0.5 smart pull routing (HF config probe)
├── MoxCLI/                # `mox` binary
├── MoxGUI/                # `MoxGUI` SwiftUI executable
├── MoxGUIClient/          # GUI-side protocol client (no MoxCore dep)
└── Tests/
    ├── MoxCoreTests/      # ConfigManager / ModelRunner / Downloader / Anthropic
    └── MoxGUIClientTests/ # AppState bootstrap + ProcessAPIClient fixtures
```

## CLI Reference

`mox` (Sources/MoxCLI):

```
pull <id> [--source hf|modelscope|mlx-community]   Download a model
list [--json]                                      List installed models
delete <id>                                        Remove a model
run <id> [--port N]                                Start daemon-bound server
chat <id>                                          REPL chat (exit: /exit, /clear)
ask --model <id> [--messages <json>] [--stream]    One-shot via OpenAI-shape JSON
-m <prompt>                                        Single-shot query (default model)
debug db … | models | daemon | open-data-dir       Developer utilities (release only)
```

`mox-server` (Sources/MoxServerCLI):

```
daemon [--host H] [--port N]    Run server in foreground (managed by launchd)
install                          Register launchd agent + bootstrap
uninstall                        Bootout launchd agent + remove plist
start                            launchctl kickstart -k <ref>
stop                             launchctl kill SIGTERM <ref>
status                           Exit-coded status (0/3/4)
logs [--stderr] [--lines N]      Tail launchd-captured logs
```

## Code Style

- Follow Swift API Design Guidelines.
- Prefer value types (`struct`, `enum`) by default. Reach for `actor`
  when concurrent state needs Swift-isolation guarantees; reach for
  `class` only when reference identity matters (NIO handlers, AppKit
  bridges).
- `Sendable` first; `nonisolated` for deliberate escape hatches only.
- Use `os.Logger` (via `moxLog`, `moxServerLog`, `moxCLILog`, `moxGUILog`
  in `MoxShared/Logging`) for all diagnostics. `print` is reserved for
  user-facing CLI output via `moxPrint` / `moxStderr`.
- Document public APIs with `///` doc comments.

## Pull Request Process

1. Branch from `dev`: `git checkout -b fix/your-topic`
2. `swift build` + `swift test` both green.
3. No new compiler warnings.
4. Commit message: imperative subject, blank line, body explaining
   *why*. Reference the relevant finding number when the change
   addresses a review.
5. Push and open a PR against `dev`.

## Reporting Issues

Include:
- `swift --version`
- `sw_vers` (macOS version)
- `uname -m` (must be `arm64`)
- Steps to reproduce
- Expected vs actual behaviour

## Architecture Notes

### Concurrency

Swift 6 strict concurrency is on. The model layer (`MoxCore`) is built
around actors: `ModelManager`, `ModelRunner`, `ConfigManager`, plus a
`SourceRegistry` for HF/ModelScope strategy wiring. NIO handlers that
hold per-connection state use `@unchecked Sendable` only because NIO's
context API requires it; the inner state is `private` and never
mutated post-init.

### Dependencies

External (declared in `Package.swift`):

| Package | | Where |
| --- | --- | --- |
| `mlx-swift` | `MLX`, `MLXNN` | MoxCore / MoxConvertCore |
| `mlx-swift-lm` | `MLXLLM`, `MLXLMCommon`, `MLXHuggingFace` | MoxCore / MoxConvertCore |
| `swift-huggingface` | `HuggingFace` | MoxCore / MoxConvertCore |
| `swift-transformers` | `Tokenizers` | MoxCore / MoxConvertCore |
| `swift-testing` | `Testing` | test targets |
| `swift-nio` | `NIOCore`, `NIOHTTP1`, `NIOPosix` | MoxServer / MoxCLI |

No third-party download libraries; native `URLSession` with HTTP Range
is the only network surface.