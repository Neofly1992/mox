# Contributing to Mox

Thank you for your interest in contributing to Mox!

## Development Setup

### Prerequisites

- Swift 6.0+
- macOS 14.0+ (Sonoma) or later
- Apple Silicon (M1/M2/M3/M4) or Intel Mac

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

## Project Structure

```
Sources/
├── MoxShared/          # Shared types: Models, API types
├── MoxCore/            # Core functionality
│   ├── ConfigManager   # Configuration management
│   ├── Downloader      # Download with resume support
│   ├── MemoryGuard     # Memory checking
│   ├── ModelManager    # Model lifecycle management
│   └── ModelRunner     # Model loading & inference
├── MoxServer/          # HTTP API server
└── MoxCLI/             # CLI entry point
```

## Code Style

- Follow Swift API Design Guidelines
- Use value types (struct) by default
- Mark concurrency-unsafe types with `@unchecked Sendable`
- Keep functions small and focused
- Add documentation for public APIs

## Pull Request Process

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## Reporting Issues

Please include:
- Swift version (`swift --version`)
- macOS version
- Steps to reproduce
- Expected vs actual behavior

## Architecture Notes

### Concurrency

The project uses Swift's native concurrency with the following patterns:

- `Sendable` protocol for thread-safe types
- `@unchecked Sendable` for classes that are manually synchronized
- `actor` for isolated state when appropriate

### Dependencies

Minimal external dependencies:
- `MLX` - Apple's MLX framework
- `swift-nio` - Async networking (server only)

No third-party download libraries; uses native `URLSession` with HTTP Range support.
