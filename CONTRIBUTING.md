# Contributing to zvdk

Thank you for considering contributing to zvdk! This document provides guidelines and instructions for contributing.

## Code of Conduct

Please be respectful and considerate of others when contributing to this project. Harassment or abusive behavior will not be tolerated.

## How to Contribute

### Reporting Bugs

Before submitting a bug report:
1. Check if the bug has already been reported in the Issues section
2. Make sure you're using the latest version of the library
3. Determine if the issue is truly a bug and not an expected behavior

When submitting a bug report, please include:
- A clear and descriptive title
- Steps to reproduce the issue
- Expected behavior
- Actual behavior
- Your environment (OS, Zig version, etc.)
- Any relevant logs or screenshots

### Suggesting Enhancements

Enhancement suggestions are always welcome. Please include:
- A clear and descriptive title
- A detailed description of the proposed enhancement
- Any potential implementation details you can provide
- Why this enhancement would be useful to most users

### Code Contributions

1. Fork the repository
2. Create a new branch for your feature (`git checkout -b feature/amazing-feature`)
3. Make your changes, following the coding standards
4. Ensure all tests pass (`zig build test`)
5. Commit your changes with clear, descriptive commit messages
6. Push your branch to your fork
7. Submit a pull request

## Pull Request Process

1. Update the README.md or documentation with details of changes if needed
2. Add tests for new functionality
3. Ensure the CI workflow passes
4. Wait for review and address any feedback

## Coding Standards

- Follow the existing code style
- Write tests for new functionality
- Document your code
- Keep functions small and focused
- Use descriptive variable names

## Zig Style Guidelines

- Follow the [Zig Style Guide](https://ziglang.org/documentation/master/#Style-Guide)
- Use snake_case for function and variable names
- Use PascalCase for types and structs
- Use descriptive names for functions and variables
- Keep lines under 100 characters when possible
- Use 4 spaces for indentation

## Testing

- All new code should have associated tests
- Tests should be thorough but concise
- Make sure all tests pass before submitting your pull request
- Consider edge cases in your tests

Thank you for your contributions!
