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

```zig
const std = @import("std");
const zvdk = @import("zvdk");

pub fn main() !void {
    // Initialize
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize RTSP client
    var client = try zvdk.rtsp.RtspClient.init(allocator, rtsp_url, .{}, null);
    defer client.deinit();

    // Connect and setup
    try client.connect();
    try client.describe();
    try client.setup();

    // Initialize components
    var h264_parser = zvdk.media.h264.H264Parser.init(allocator);
    defer h264_parser.deinit();
    
    var ts_encoder = zvdk.ts.TsEncoder.init(allocator);
    defer ts_encoder.deinit();
    
    var segmenter = try zvdk.ts.Segmenter.init(allocator, output_dir, 10000, 6);
    defer segmenter.deinit();

    // Start HLS server
    var hls_server = try zvdk.hls.HlsServer.init(allocator, output_dir, 8080);
    _ = try std.Thread.spawn(.{}, hls_server.start, .{});

    // Start playing
    try client.play();
    
    // Process frames
    while (true) {
        // Process RTSP stream
        // See full example in examples directory
    }

    // Clean up
    client.teardown();
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
