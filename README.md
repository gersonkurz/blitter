# Blitter

Blazingly fast file manager for macOS.

Blitter is a native macOS file manager in the spirit of Directory Opus: two side-by-side listers, each with a folder tree, built for keyboard-driven work and speed. The name comes from the Amiga's Blitter chip, whose job was moving blocks of memory around very fast.

It exists because Path Finder became unusable, and nothing else on the Mac comes close to the DOpus workflow.

**Status:** planning. See [docs/PLAN.md](docs/PLAN.md).

## Principles

- **Native and fast.** Swift and AppKit, direct kernel APIs on the hot paths, nothing blocking the main thread.
- **Mac only.** Blitter is built around macOS: APFS, FSEvents, File Provider cloud drives, Quick Look, Spotlight.
- **Automated through AI, not a scripting language.** Blitter will run as an MCP server that Claude or Codex can drive.
- **Shaped by daily use.** Start with a tight MVP, then add features based on what actually gets in the way.

## License

MIT, see [LICENSE](LICENSE).
