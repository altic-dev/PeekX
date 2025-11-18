# PeekX

A native macOS Quick Look extension that provides instant previews of folder contents, including file counts, size statistics, and detailed folder analysis.

---

> **⭐ Support This Project**  
> If you find PeekX useful, please consider starring this repository! Unlike similar apps that cost $5-10, PeekX is completely free and open source. **A star is the only payment I ask for** - it helps others discover the project and motivates continued development.
>
> [⭐ Star this repo](https://github.com/altic-dev/PeekX) • It takes just one click!

---

## Overview

PeekX enhances the macOS Quick Look feature by allowing you to preview the contents of any folder without opening it. Simply select a folder in Finder and press Space to see a comprehensive breakdown of its contents, including file types, sizes, and structure.

## Features

- **Instant Folder Preview** - View folder contents directly in Quick Look
- **File Statistics** - See total file count, folder size, and file type breakdown
- **Modern Interface** - Clean, native macOS design that matches system aesthetics
- **Lightweight** - Minimal resource usage with fast rendering
- **Sandboxed** - Fully sandboxed for security and privacy
- **Universal Binary** - Supports both Apple Silicon and Intel Macs

## Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon or Intel processor

## Installation

### Option 1: Download Release (Recommended)

1. Download the latest `PeekX-X.X.dmg` from the [Releases](https://github.com/altic-dev/PeekX/releases) page
2. Open the DMG file
3. Drag PeekX to your Applications folder
4. Launch PeekX once to register the Quick Look extension
5. The app will automatically register and quit

### Option 2: Build from Source

```bash
# Clone the repository
git clone https://github.com/altic-dev/PeekX.git
cd PeekX

# Open in Xcode and build
open PeekX.xcodeproj
# Build the PeekX scheme (Cmd+B)
```

## Usage

Once installed, using PeekX is straightforward:

1. Open Finder
2. Navigate to any folder
3. Select the folder
4. Press **Space** or click the Quick Look button
5. View instant folder analysis and contents

The Quick Look preview will display:
- Total number of files and subfolders
- Total folder size
- Breakdown by file type
- Large file identification
- Folder structure visualization

## Uninstallation

To remove PeekX:

1. Quit PeekX if running
2. Delete `PeekX.app` from your Applications folder
3. (Optional) Reset Quick Look cache:
   ```bash
   qlmanage -r cache
   killall Finder
   ```

## Development

### Project Structure

```
PeekX/
├── PeekX/                  # Main application
│   ├── PeekXApp.swift     # App entry point
│   └── Assets.xcassets/   # App icons and resources
├── PeekXExt/              # Quick Look extension
│   ├── PreviewViewController.swift  # Main preview logic
│   └── Info.plist         # Extension configuration
└── Shared/                # Shared code between app and extension
    ├── Constants.swift
    └── SharedSettings.swift
```

### Building

Open the project in Xcode and build the PeekX scheme. The extension will be automatically embedded in the main application bundle.

## Architecture

PeekX consists of two main components:

1. **Main Application (PeekX.app)** - A lightweight background agent that registers the Quick Look extension on launch
2. **Quick Look Extension (PeekXExt.appex)** - The extension that handles folder preview generation

The extension uses native macOS APIs to analyze folder contents and render previews using WebKit for a modern, responsive interface.

## Privacy

PeekX respects your privacy:

- Runs entirely on your Mac with no network access
- Does not collect or transmit any data
- Fully sandboxed with minimal system permissions
- Only accesses folders you explicitly view in Quick Look

## Troubleshooting

### Extension not showing up

If the Quick Look extension doesn't appear after installation:

1. Ensure PeekX.app is in `/Applications`
2. Launch PeekX once to register the extension
3. Reset Quick Look cache:
   ```bash
   qlmanage -r cache
   killall Finder
   ```
4. Check extension status:
   ```bash
   pluginkit -m -v -p com.apple.quicklook.preview | grep PeekX
   ```

### Permission issues

If you see permission errors, verify that:
- PeekX has necessary permissions in System Settings
- The app is properly code-signed
- You're running macOS 14.0 or later

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

### Guidelines

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/your-feature`)
3. Commit your changes (`git commit -am 'Add new feature'`)
4. Push to the branch (`git push origin feature/your-feature`)
5. Create a Pull Request

Please ensure your code:
- Follows Swift style guidelines
- Includes appropriate comments
- Maintains compatibility with macOS 14.0+
- Does not introduce new dependencies without discussion

## License

PeekX is licensed under the MIT License. See [LICENSE](LICENSE) for details.

Copyright (c) 2025 ALTIC

## Acknowledgments

Built with:
- Swift and SwiftUI
- macOS Quick Look APIs


## Support

### Bug Reports

Found a bug? Please report it on [GitHub Issues](https://github.com/altic-dev/PeekX/issues):

- Check existing issues first to avoid duplicates
- Include your macOS version and system information
- Provide steps to reproduce the issue
- Attach relevant logs or screenshots if possible

### Feature Requests

Have an idea for a new feature? We'd love to hear it!

- Open a feature request on [GitHub Issues](https://github.com/altic-dev/PeekX/issues)
- Describe the feature and why it would be useful
- Include any mockups or examples if applicable
- Label your issue with "enhancement"

All feature requests are reviewed and prioritized based on community interest and feasibility.

