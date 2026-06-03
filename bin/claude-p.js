#!/usr/bin/env node
// Thin shim that execs the platform-specific prebuilt `claude-p` binary
// downloaded by scripts/install.js into ../prebuilt/.

const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

function platformDir() {
  const platform = process.platform;
  const arch = process.arch;
  return `${platform}-${arch}`;
}

function binaryPath() {
  const name = process.platform === "win32" ? "claude-p.exe" : "claude-p";
  // custom (build-on-install): prefer the binary produced by `prepare`
  // (`zig build` → zig-out/bin/), which carries this fork's patch. Fall back to
  // a downloaded/bundled prebuilt only if no local build exists.
  const built = path.join(__dirname, "..", "zig-out", "bin", name);
  if (fs.existsSync(built)) return built;
  const dir = path.join(__dirname, "..", "prebuilt", platformDir());
  return path.join(dir, name);
}

function main() {
  const bin = binaryPath();
  if (!fs.existsSync(bin)) {
    console.error(
      `claude-p: binary not found at ${bin}\n` +
        `This fork builds on install via \`zig build\` (needs Zig 0.15.2 on PATH).\n` +
        `Re-run the install with Zig available, or build manually with \`zig build -Doptimize=ReleaseSafe\`.`,
    );
    process.exit(2);
  }
  const result = spawnSync(bin, process.argv.slice(2), {
    stdio: "inherit",
  });
  if (result.error) {
    console.error("claude-p:", result.error.message);
    process.exit(2);
  }
  if (result.signal) {
    process.kill(process.pid, result.signal);
    return;
  }
  process.exit(result.status ?? 0);
}

main();
