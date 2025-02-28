# zvdk

A high-performance RTSP to HLS conversion library written in Zig 0.13, focusing on memory efficiency and minimal external dependencies.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

## Features

- RTSP client for connecting to RTSP servers (supports RTSP 1.0)
- Media parsing for H.264, H.265, and AAC
- Transport Stream (TS) segment creation
- HLS playlist generation and serving
- Customizable segment duration and retention
- Support for both live and dummy RTSP URLs for testing
- Zero external dependencies - pure Zig implementation
- Memory-efficient design for embedded and high-performance applications

## Requirements

- Zig 0.13.0 or later
- No additional dependencies required

## Building

```bash
# Clone the repository
git clone https://github.com/yourusername/zvdk.git
cd zvdk

# Build the library and executable
zig build

# Run tests
zig build test
```

## Usage

### Command Line

```bash
# Basic usage
./zig-out/bin/zvdk <rtsp_url> [output_dir] [port]

# Example
./zig-out/bin/zvdk rtsp://example.com/stream segments 8080
```

### As a Library

You can include zvdk in your Zig project in several ways:

#### Option 1: Using Zig Build System
```zig
const std = @import("std");
const zvdk = @import("zvdk");

pub fn main() !void {
    var client = try RtspClient.init(allocator);
    defer client.deinit();
    
    try client.connect("rtsp://example.com/stream");
    try client.setup();
    try client.play();
    
    // Process frames
    while (client.isPlaying()) {
        // Process RTSP stream
        // See full example in examples directory
    }
    
    // Clean up
    client.teardown();
}
```

#### Option 2: Using Zig Package Manager (zon)

Add zvdk to your `build.zig.zon` file:

```zig
.{
    .name = "your-app",
    .version = "0.1.0",
    .dependencies = .{
        .zvdk = .{
            .url = "https://github.com/bkataru/zvdk/archive/refs/tags/v0.1.0.tar.gz",
            .hash = "12200...", // Replace with the actual hash after adding the dependency
        },
    },
}
```

Then, in your `build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "your-app",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    // Add zvdk as a dependency
    const zvdk_dep = b.dependency("zvdk", .{
        .target = target,
        .optimize = optimize,
    });
    exe.addModule("zvdk", zvdk_dep.module("zvdk"));

    b.installArtifact(exe);
}
```

In your code, you can then import and use zvdk:

```zig
const std = @import("std");
const zvdk = @import("zvdk");

pub fn main() !void {
    // Your code using zvdk
}
```

## API Documentation

See the [API Documentation](docs/API.md) for detailed information about using the library.

## Testing

The library includes comprehensive tests:

```bash
# Run all tests
zig build test

# Run specific test
zig build test -- --filter="hls"
```

For more advanced testing, the library includes a mock RTSP server that can be used for testing without a real RTSP source.

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for detailed information about the project structure and component interactions.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

Please ensure your code passes all tests and follows the Zig coding style.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Inspired by various media processing libraries and RTSP clients
- Thanks to the Zig community for the great language and tools
- Special thanks to the following open source projects that provided valuable references:
  - [media-server](https://github.com/ireader/media-server) - A comprehensive C/C++ implementation of various media protocols
  - [cpp_hls](https://github.com/pedro-vicente/cpp_hls) - A C++ implementation of HLS streaming
  - [vdk](https://github.com/deepch/vdk) - Go Video Development Kit with RTSP, RTMP, and HLS support