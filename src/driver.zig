//! End-to-end driver: spawn `claude` under a zmux NativeSession, drive the UI
//! with our prompt, wait for the Stop hook, and return a Result.
const std = @import("std");
const zmux = @import("zmux");

const args_mod = @import("args.zig");
const transcript_mod = @import("transcript.zig");
const emit_mod = @import("emit.zig");
const hook_mod = @import("hook.zig");
const terminal_mod = @import("terminal.zig");
const stream_mod = @import("stream.zig");

pub const Options = struct {
    prompt: []const u8,
    output_format: args_mod.OutputFormat = .text,
    model: ?[]const u8 = null,
    max_turns: ?u32 = null,
    allowed_tools: ?[]const u8 = null,
    skip_permissions: bool = false,
    resume_session: ?[]const u8 = null,
    cont: bool = false,
    session_id: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    extra_args: []const []const u8 = &.{},
    /// Explicit support for high-value claude flags. These are forwarded to
    /// the child as the corresponding `claude` flag.
    system_prompt: ?[]const u8 = null,
    append_system_prompt: ?[]const u8 = null,
    permission_mode: ?[]const u8 = null,
    disallowed_tools: ?[]const u8 = null,
    fallback_model: ?[]const u8 = null,
    setting_sources: ?[]const u8 = null,
    add_dirs: []const []const u8 = &.{},
    mcp_configs: []const []const u8 = &.{},
    /// Optional MCP-readiness sentinel. When set, the driver types the prompt as
    /// soon as Ink is quiescent but HOLDS the submit Enter until this file
    /// exists. The bridge's MCP shim creates it the moment it has served
    /// `tools/list` — i.e. once the bridged tool surface is actually live in
    /// `claude`. This closes the boot race where the prompt is submitted before
    /// the MCP tools are registered, which makes the model emit tool calls as
    /// raw text. Absent → submit as soon as the prompt echoes (legacy behavior).
    mcp_ready_file: ?[]const u8 = null,
    verbose: bool = false,
    timeout_ms: u64 = 300_000,
    /// Override `claude` binary path (testing).
    claude_path: ?[]const u8 = null,
    cols: u16 = 120,
    rows: u16 = 40,
    debug: bool = false,
    /// When set and `output_format` is `.stream_json`, the driver tails the
    /// session transcript and writes each JSONL line to this writer as it
    /// is flushed by the child `claude`. After Stop, the driver writes the
    /// final `result` envelope and flushes. Result.streamed is set to true
    /// so callers can avoid re-emitting via Result.write.
    stream_writer: ?*std.Io.Writer = null,
};

pub const Result = struct {
    summary: transcript_mod.Summary,
    duration_ms: u64,
    /// True if `run()` already streamed stream-json output to the caller's
    /// `stream_writer`. `Result.write` is a no-op for `.stream_json` in that
    /// case to avoid double-emit.
    streamed: bool = false,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        self.summary.deinit(allocator);
    }

    pub fn write(
        self: *const Result,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        fmt: args_mod.OutputFormat,
    ) !void {
        if (self.streamed and fmt == .stream_json) return;
        try emit_mod.emit(allocator, writer, fmt, .{
            .summary = &self.summary,
            .duration_ms = self.duration_ms,
        });
    }

    pub fn exitCode(self: *const Result) u8 {
        return if (self.summary.is_error) 1 else 0;
    }
};

pub const RunError = error{
    SessionStartTimeout,
    StopTimeout,
    TranscriptUnavailable,
    SpawnFailed,
    NoPromptSupplied,
    // custom: the typed prompt never echoed back into Ink's input box within
    // the bounded retype budget (input dropped by a not-yet-ready TUI). Fail
    // fast instead of waiting --timeout for a Stop hook that can never fire.
    PromptNotAccepted,
    // custom: the MCP-readiness sentinel (Options.mcp_ready_file) never appeared
    // within mcp_ready_max_wait_ms after the prompt echoed. We refuse to submit a
    // prompt that would generate with NO bridged tools (the model would emit tool
    // calls as text). Fail fast; the caller retries on a fresh spawn.
    McpNotReady,
} || std.mem.Allocator.Error;

/// Build the argv for the child `claude` invocation.
pub fn buildArgv(
    allocator: std.mem.Allocator,
    binary: []const u8,
    settings_json: []const u8,
    opts: Options,
) !std.ArrayList([]const u8) {
    var argv: std.ArrayList([]const u8) = .{};
    errdefer argv.deinit(allocator);

    try argv.append(allocator, binary);
    try argv.append(allocator, "--settings");
    try argv.append(allocator, settings_json);
    if (opts.model) |m| {
        try argv.append(allocator, "--model");
        try argv.append(allocator, m);
    }
    if (opts.max_turns) |n| {
        try argv.append(allocator, "--max-turns");
        try argv.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{n}));
    }
    if (opts.allowed_tools) |t| {
        try argv.append(allocator, "--allowedTools");
        try argv.append(allocator, t);
    }
    if (opts.skip_permissions) {
        try argv.append(allocator, "--dangerously-skip-permissions");
    }
    if (opts.resume_session) |id| {
        try argv.append(allocator, "--resume");
        try argv.append(allocator, id);
    }
    if (opts.cont) try argv.append(allocator, "--continue");
    if (opts.session_id) |id| {
        try argv.append(allocator, "--session-id");
        try argv.append(allocator, id);
    }
    if (opts.verbose) try argv.append(allocator, "--verbose");

    if (opts.system_prompt) |s| {
        try argv.append(allocator, "--system-prompt");
        try argv.append(allocator, s);
    }
    if (opts.append_system_prompt) |s| {
        try argv.append(allocator, "--append-system-prompt");
        try argv.append(allocator, s);
    }
    if (opts.permission_mode) |s| {
        try argv.append(allocator, "--permission-mode");
        try argv.append(allocator, s);
    }
    if (opts.disallowed_tools) |s| {
        try argv.append(allocator, "--disallowedTools");
        try argv.append(allocator, s);
    }
    if (opts.fallback_model) |s| {
        try argv.append(allocator, "--fallback-model");
        try argv.append(allocator, s);
    }
    if (opts.setting_sources) |s| {
        try argv.append(allocator, "--setting-sources");
        try argv.append(allocator, s);
    }
    for (opts.add_dirs) |d| {
        try argv.append(allocator, "--add-dir");
        try argv.append(allocator, d);
    }
    for (opts.mcp_configs) |c| {
        try argv.append(allocator, "--mcp-config");
        try argv.append(allocator, c);
    }

    for (opts.extra_args) |a| try argv.append(allocator, a);
    return argv;
}

/// Join argv into a single shell-safe command line (single-quoting each arg).
pub fn shellQuoteArgv(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    for (argv, 0..) |a, idx| {
        if (idx > 0) try buf.append(allocator, ' ');
        try shellQuoteOne(allocator, &buf, a);
    }
    return try buf.toOwnedSlice(allocator);
}

fn shellQuoteOne(allocator: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(allocator, '\'');
    for (s) |c| {
        if (c == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, c);
        }
    }
    try out.append(allocator, '\'');
}

/// How long the PTY output stream must be quiet before we believe Ink has
/// finished its initial render and is ready to accept keystrokes. Smaller
/// values type sooner; too small risks racing Ink's prompt-box draw. Tuned
/// to 80 ms based on observed bursts (the input box renders in <50 ms of
/// continuous output, then goes silent).
const ink_quiescence_ms: u64 = 80;

/// Upper bound on how long we'll wait for quiescence. If Ink keeps emitting
/// output past this, we give up and type anyway; in practice the prompt box
/// is always up by then, and the failure mode is identical to the previous
/// fixed-sleep behavior.
const ink_max_wait_ms: u64 = 2000;

/// How long to wait between sending the prompt bytes and sending Enter.
/// Ink's bracketed-paste heuristic merges back-to-back writes; without a
/// gap, `\r` lands in the input buffer instead of triggering submit.
const ink_enter_debounce_ms: u64 = 120;

// --- custom (echo-confirmed input) ---
// After typing the prompt, confirm it actually echoed into Ink's input box
// before committing Enter, instead of trusting a blind debounce. Under
// concurrent-boot CPU contention the SessionStart hook can fire while Ink's
// input pipeline is not yet ready; the keystrokes are then dropped, the turn
// never starts, and no Stop hook ever fires — the wrapper wedges until
// --timeout. We poll the rolling `recent` PTY buffer for the prompt echo,
// clear-line + retype on a miss, and fail fast rather than wedge.
const echo_confirm_window_ms: u64 = 750; // per-attempt wait for the echo
const echo_confirm_max_attempts: usize = 3;
const echo_needle_max: usize = 48; // alnum chars of the prompt used as the echo needle

// --- custom (MCP-readiness gate) ---
// After the prompt echoes we HOLD the submit Enter until the MCP shim's
// readiness sentinel (Options.mcp_ready_file) appears, so the turn never
// generates before the bridged `mcp__custom-tools__*` surface is live in
// `claude`. `claude` requests tools/list at boot, so the shim normally raises
// this within ~1-2s; a miss means the shim died or never attached, and we fail
// fast (McpNotReady) rather than submit a tool-less prompt or wedge to --timeout.
const mcp_ready_max_wait_ms: u64 = 20_000;

/// True if an absolute path exists and is accessible. Used to poll for the
/// MCP-readiness sentinel without blocking the main loop.
fn fileExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

/// Block until the child PTY has been quiet for at least `ink_quiescence_ms`,
/// up to a cap of `ink_max_wait_ms`. Replaces the hardcoded "give Ink time
/// to settle" sleep from the original fix — adapts to whatever boot latency
/// the machine actually has.
fn waitForInkQuiescent(opts: Options, trace_start: i128, shared: *SharedState) void {
    const quiescence_ns: i64 = @intCast(ink_quiescence_ms * std.time.ns_per_ms);
    const max_ns: i64 = @intCast(ink_max_wait_ms * std.time.ns_per_ms);
    const wait_started: i64 = @intCast(std.time.nanoTimestamp());
    while (true) {
        const now: i64 = @intCast(std.time.nanoTimestamp());
        if (now - wait_started > max_ns) {
            traceFmt(opts, trace_start, "Ink readiness wait hit max ({d}ms) — typing anyway", .{ink_max_wait_ms});
            return;
        }
        const last: i64 = shared.last_output_ns.load(.seq_cst);
        if (last != 0 and now - last > quiescence_ns) {
            const since_ms: i64 = @divTrunc(now - last, std.time.ns_per_ms);
            const waited_ms: i64 = @divTrunc(now - wait_started, std.time.ns_per_ms);
            traceFmt(opts, trace_start, "Ink quiescent (output silent for {d}ms, waited {d}ms total)", .{ since_ms, waited_ms });
            return;
        }
        std.Thread.sleep(15 * std.time.ns_per_ms);
    }
}

/// Emit a debug-gated trace line to stderr with the elapsed time since
/// `start`. Lets the user pinpoint where the latency in a `--debug` run is
/// going: hook harness setup, claude/Ink boot, first transcript flush, etc.
fn trace(opts: Options, start: i128, label: []const u8) void {
    if (!opts.debug) return;
    const now: i128 = std.time.nanoTimestamp();
    const elapsed_ms: i64 = @intCast(@divTrunc(now - start, std.time.ns_per_ms));
    std.debug.print("[claude-p +{d}ms] {s}\n", .{ elapsed_ms, label });
}

fn traceFmt(opts: Options, start: i128, comptime fmt: []const u8, args: anytype) void {
    if (!opts.debug) return;
    const now: i128 = std.time.nanoTimestamp();
    const elapsed_ms: i64 = @intCast(@divTrunc(now - start, std.time.ns_per_ms));
    std.debug.print("[claude-p +{d}ms] ", .{elapsed_ms});
    std.debug.print(fmt, args);
    std.debug.print("\n", .{});
}

// Thread-shared state between the NativeSession reader thread and the
// driver's main loop.
const SharedState = struct {
    session: *zmux.NativeSession,
    debug: bool,
    // Bytes the DEC responder wants written back to the PTY. Mutex-guarded.
    write_mutex: std.Thread.Mutex = .{},
    pending_to_pty: std.ArrayList(u8) = .{},
    bytes_seen: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Timestamp (ns since arbitrary epoch — std.time.nanoTimestamp, truncated
    /// to i64). Used by the main loop to decide when Ink has gone quiescent
    /// (UI rendering done) and is therefore ready to accept keystrokes —
    /// replaces a previous hardcoded 1500 ms sleep. Stored as i64 because
    /// Zig's atomic load/store doesn't support 128-bit integers on all
    /// targets (e.g. x86_64-linux-musl); i64 ns gives ~292 years of range,
    /// vastly more than we need.
    last_output_ns: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    exited: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    // Rolling buffer of recently-seen output. The driver loop scans this
    // for the workspace-trust dialog (shown in unfamiliar directories,
    // not bypassed by --dangerously-skip-permissions) and dismisses it
    // by pressing Enter.
    recent_mutex: std.Thread.Mutex = .{},
    recent: std.ArrayList(u8) = .{},
    trust_dismissed: bool = false,
};

const recent_capacity: usize = 8192;

fn onZmuxEvent(ctx: *anyopaque, event: zmux.native.Event) void {
    const shared: *SharedState = @ptrCast(@alignCast(ctx));
    switch (event) {
        .pane_output => |po| {
            _ = shared.bytes_seen.fetchAdd(po.data.len, .seq_cst);
            shared.last_output_ns.store(@intCast(std.time.nanoTimestamp()), .seq_cst);
            // Run the DEC-query responder; queue responses for the main loop.
            var resp: std.ArrayList(u8) = .{};
            defer resp.deinit(std.heap.page_allocator);
            terminal_mod.respondToDecQueries(std.heap.page_allocator, po.data, &resp) catch {};
            if (resp.items.len > 0) {
                shared.write_mutex.lock();
                shared.pending_to_pty.appendSlice(std.heap.page_allocator, resp.items) catch {};
                shared.write_mutex.unlock();
            }
            // Update the rolling recent-output buffer for trust-dialog
            // detection in the main loop.
            shared.recent_mutex.lock();
            shared.recent.appendSlice(std.heap.page_allocator, po.data) catch {};
            if (shared.recent.items.len > recent_capacity) {
                const drop = shared.recent.items.len - recent_capacity;
                std.mem.copyForwards(
                    u8,
                    shared.recent.items[0 .. recent_capacity],
                    shared.recent.items[drop..],
                );
                shared.recent.shrinkRetainingCapacity(recent_capacity);
            }
            shared.recent_mutex.unlock();
            if (shared.debug) std.debug.print("zmux pane_output: {d} bytes\n", .{po.data.len});
        },
        .session_exited => |se| {
            shared.exited.store(true, .seq_cst);
            if (shared.debug) std.debug.print("zmux session_exited: code={?d} signal={?d}\n", .{ se.exit_code, se.signal });
        },
        .pane_activity, .pane_bell, .foreground_changed => {},
    }
}

pub fn run(allocator: std.mem.Allocator, opts: Options) !Result {
    if (opts.prompt.len == 0) return RunError.NoPromptSupplied;

    const trace_start: i128 = std.time.nanoTimestamp();
    trace(opts, trace_start, "run() entered");

    var harness = try hook_mod.create(allocator);
    defer harness.deinit();
    trace(opts, trace_start, "hook harness ready (FIFO + relay script + --settings)");

    const claude_bin = opts.claude_path orelse "claude";

    var argv = try buildArgv(allocator, claude_bin, harness.settings_json, opts);
    defer {
        // Some entries (max-turns) are heap-allocated by buildArgv. We can't
        // tell which without tracking, so we just leak the small strings —
        // the process is short-lived. (TODO: refactor buildArgv to track
        // owned entries.)
        argv.deinit(allocator);
    }

    const shell_cmd = try shellQuoteArgv(allocator, argv.items);
    defer allocator.free(shell_cmd);

    // Compose env: forward the FIFO path; force TERM; include the existing
    // environment so PATH etc. is preserved.
    var env_list: std.ArrayList([]const u8) = .{};
    defer {
        for (env_list.items) |s| allocator.free(s);
        env_list.deinit(allocator);
    }
    // Inherit existing environment.
    var env_iter = try std.process.getEnvMap(allocator);
    defer env_iter.deinit();
    var it = env_iter.iterator();
    while (it.next()) |e| {
        try env_list.append(
            allocator,
            try std.fmt.allocPrint(allocator, "{s}={s}", .{ e.key_ptr.*, e.value_ptr.* }),
        );
    }
    try env_list.append(
        allocator,
        try std.fmt.allocPrint(allocator, "CLAUDE_P_FIFO={s}", .{harness.fifo_path}),
    );
    try env_list.append(allocator, try allocator.dupe(u8, "TERM=xterm-256color"));

    // Open the FIFO for reading BEFORE spawning so the child's hook never
    // blocks trying to open the write side.
    const fifo_z = try allocator.dupeZ(u8, harness.fifo_path);
    defer allocator.free(fifo_z);
    const fifo_fd = std.posix.openZ(fifo_z, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0) catch return RunError.SpawnFailed;
    defer std.posix.close(fifo_fd);

    var shared: SharedState = .{
        .session = undefined, // set after create
        .debug = opts.debug,
    };
    defer {
        shared.write_mutex.lock();
        shared.pending_to_pty.deinit(std.heap.page_allocator);
        shared.write_mutex.unlock();
        shared.recent_mutex.lock();
        shared.recent.deinit(std.heap.page_allocator);
        shared.recent_mutex.unlock();
    }

    const sink: zmux.native.EventSink = .{
        .context = @ptrCast(&shared),
        .emit = onZmuxEvent,
    };

    const session = zmux.NativeSession.create(allocator, .{
        .id = "claude-p",
        .shell = "/bin/sh",
        .command = shell_cmd,
        .cwd = opts.cwd,
        .env = env_list.items,
        .rows = opts.rows,
        .cols = opts.cols,
        .event_sink = sink,
    }) catch return RunError.SpawnFailed;
    shared.session = session;
    defer session.destroy();
    trace(opts, trace_start, "zmux session spawned; child claude PID up, Ink booting");

    const start_ns: i128 = trace_start;
    // waiting_for_ready  → before SessionStart / prompt typed
    // waiting_for_mcp_ready → prompt is typed+echoed, Enter HELD pending the MCP
    //   readiness sentinel (only entered when opts.mcp_ready_file is set)
    // awaiting_stop      → Enter sent, waiting on the Stop hook
    var state: enum { waiting_for_ready, waiting_for_mcp_ready, awaiting_stop } = .waiting_for_ready;
    var mcp_ready_deadline_ns: i128 = 0;
    var first_emit_logged = false;
    var total_lines_streamed: usize = 0;

    var fifo_buf: std.ArrayList(u8) = .{};
    defer fifo_buf.deinit(allocator);
    var fifo_read_buf: [4096]u8 = undefined;

    var transcript_path: ?[]u8 = null;
    defer if (transcript_path) |p| allocator.free(p);
    var stop_payload_owned: ?[]u8 = null;
    defer if (stop_payload_owned) |p| allocator.free(p);

    // Resume-staleness baseline: the number of assistant turns already in the
    // transcript BEFORE we submit the live prompt. The live turn must push the
    // count past this; until it does, any Stop/parse reflects a REPLAYED prior
    // turn (the `--resume` stale-result race). Captured at echo-confirm, below.
    var baseline_turns: u32 = 0;

    // Live transcript tailer. Opened lazily once we learn `transcript_path`
    // (typically from the SessionStart hook payload). Only used when the
    // caller requested stream-json output AND supplied a writer.
    //
    // The transcript_path arrives in the SessionStart payload but the file
    // itself may not exist on disk until claude flushes its first line —
    // so opening can fail at SessionStart and needs to be retried in the
    // main loop until it succeeds. Without this retry the streaming path
    // degenerates to a single post-Stop dump, which is the "12s of silence
    // then everything at once" symptom users see.
    const streaming = opts.output_format == .stream_json and opts.stream_writer != null;
    var tailer: ?stream_mod.Tailer = null;
    defer if (tailer) |*t| t.deinit();
    var tailer_open_attempts: u32 = 0;

    while (true) {
        const now: i128 = std.time.nanoTimestamp();
        const elapsed_ms: u64 = @intCast(@divTrunc(now - start_ns, std.time.ns_per_ms));
        if (elapsed_ms > opts.timeout_ms) {
            if (state == .waiting_for_ready) return RunError.SessionStartTimeout;
            if (state == .waiting_for_mcp_ready) return RunError.McpNotReady;
            return RunError.StopTimeout;
        }
        if (shared.exited.load(.seq_cst) and
            (state == .waiting_for_ready or state == .waiting_for_mcp_ready))
        {
            return RunError.SpawnFailed;
        }

        // MCP-readiness gate: the prompt is typed and echoed; we hold the submit
        // Enter here (the main loop keeps servicing the PTY) until the shim's
        // sentinel appears, then submit. Fail fast if it never shows.
        if (state == .waiting_for_mcp_ready) {
            if (opts.mcp_ready_file) |rf| {
                if (fileExists(rf)) {
                    std.Thread.sleep(ink_enter_debounce_ms * std.time.ns_per_ms);
                    session.send("", true) catch {};
                    trace(opts, trace_start, "MCP surface ready; Enter sent; waiting on claude API");
                    state = .awaiting_stop;
                } else if (now > mcp_ready_deadline_ns) {
                    traceFmt(opts, trace_start, "MCP readiness sentinel never appeared within {d}ms — failing fast (McpNotReady)", .{mcp_ready_max_wait_ms});
                    return RunError.McpNotReady;
                }
            }
        }

        // Flush any DEC-responder bytes back to the PTY.
        shared.write_mutex.lock();
        const to_write = if (shared.pending_to_pty.items.len > 0)
            try allocator.dupe(u8, shared.pending_to_pty.items)
        else
            null;
        if (to_write != null) shared.pending_to_pty.clearRetainingCapacity();
        shared.write_mutex.unlock();
        if (to_write) |bytes| {
            session.writeInput(bytes) catch {};
            allocator.free(bytes);
        }

        // Workspace-trust dialog detection. Claude shows a "Is this a project
        // you trust?" prompt in unfamiliar directories that blocks startup
        // *before* SessionStart hooks register and is not bypassed by
        // --dangerously-skip-permissions. Default selection is "Yes, I trust
        // this folder"; Enter accepts.
        if (!shared.trust_dismissed and state == .waiting_for_ready) {
            shared.recent_mutex.lock();
            const stripped = try stripCsi(allocator, shared.recent.items);
            shared.recent_mutex.unlock();
            defer allocator.free(stripped);
            // After stripping CSI, words are concatenated (because the dialog
            // pads with `\033[1C` cursor-move, not real spaces). Search for
            // two distinct single-word markers both being present in the
            // pre-SessionStart output stream.
            const has_trust = std.mem.indexOf(u8, stripped, "trust") != null;
            const has_folder = std.mem.indexOf(u8, stripped, "folder") != null;
            if (has_trust and has_folder) {
                trace(opts, trace_start, "workspace-trust dialog detected — sending Enter to dismiss");
                session.send("", true) catch {};
                shared.trust_dismissed = true;
            }
        }

        // Drain the FIFO.
        const fifo_n = std.posix.read(fifo_fd, &fifo_read_buf) catch |e| switch (e) {
            error.WouldBlock => 0,
            else => 0,
        };
        if (fifo_n > 0) {
            try fifo_buf.appendSlice(allocator, fifo_read_buf[0..fifo_n]);
            while (true) {
                const nl = std.mem.indexOfScalar(u8, fifo_buf.items, '\n') orelse break;
                const line = fifo_buf.items[0..nl];
                if (hook_mod.parseLine(line)) |ev| {
                    if (opts.debug) std.debug.print("hook: {s} payload={s}\n", .{ @tagName(ev.event), ev.payload });
                    switch (ev.event) {
                        .session_start => {
                            trace(opts, trace_start, "SessionStart hook fired (Ink is up)");
                            // SessionStart payloads carry the transcript
                            // path. Stash it so the main loop can keep
                            // trying to open the tailer until the file
                            // actually exists on disk.
                            if (streaming and transcript_path == null) {
                                if (try hook_mod.extractTranscriptPath(allocator, ev.payload)) |p| {
                                    transcript_path = p;
                                    traceFmt(opts, trace_start, "transcript_path from SessionStart: {s}", .{p});
                                }
                            }
                            if (state == .waiting_for_ready) {
                                // Wait for Ink to finish its initial render
                                // before sending keystrokes. Signal: the PTY
                                // output stream has been quiet for the
                                // quiescence threshold below. Adaptive —
                                // fast machines proceed in <100 ms, slow
                                // ones get up to ink_max_wait_ms before we
                                // give up and type anyway.
                                waitForInkQuiescent(opts, trace_start, &shared);

                                // custom (echo-confirmed input): type the
                                // prompt, then CONFIRM it echoed into Ink's
                                // input box before committing Enter. Prompt and
                                // `\r` are still sent as two events (Ink's
                                // bracketed-paste heuristic merges back-to-back
                                // writes, so a same-burst `\r` would land in the
                                // buffer instead of submitting). Under
                                // concurrent-boot contention the keystrokes can
                                // be dropped by a not-yet-ready TUI; retype
                                // (clear-line first, so a partial can't
                                // concatenate) up to echo_confirm_max_attempts,
                                // then fail fast rather than wedge until
                                // --timeout for a Stop that can never come.
                                var attempt: usize = 0;
                                var confirmed = false;
                                while (attempt < echo_confirm_max_attempts and !confirmed) : (attempt += 1) {
                                    if (attempt > 0) {
                                        // Ctrl-U kills the input line so a
                                        // partially-accepted prior attempt
                                        // cannot concatenate into a corrupt prompt.
                                        session.send("\x15", false) catch {};
                                        std.Thread.sleep(40 * std.time.ns_per_ms);
                                    }
                                    traceFmt(opts, trace_start, "typing prompt ({d} bytes), attempt {d}", .{ opts.prompt.len, attempt + 1 });
                                    session.send(opts.prompt, false) catch {};

                                    const echo_window_ns: i64 = @intCast(echo_confirm_window_ms * std.time.ns_per_ms);
                                    const echo_wait_start: i64 = @intCast(std.time.nanoTimestamp());
                                    while (true) {
                                        if (promptEchoConfirmed(allocator, &shared, opts.prompt) catch false) {
                                            confirmed = true;
                                            break;
                                        }
                                        const echo_now: i64 = @intCast(std.time.nanoTimestamp());
                                        if (echo_now - echo_wait_start > echo_window_ns) break;
                                        std.Thread.sleep(25 * std.time.ns_per_ms);
                                    }
                                }

                                if (!confirmed) {
                                    traceFmt(opts, trace_start, "prompt echo never confirmed after {d} attempt(s) — failing fast (PromptNotAccepted)", .{echo_confirm_max_attempts});
                                    return RunError.PromptNotAccepted;
                                }

                                // Resume-staleness guard: snapshot how many assistant
                                // turns the transcript already has BEFORE submit. The
                                // prompt is echoed into Ink's input box but NOT yet
                                // committed, so the transcript still ends at the prior
                                // turn. The live turn must push this count higher
                                // before its result is trusted (driver post-Stop loop).
                                baseline_turns = transcript_mod.turnCountFile(allocator, transcript_path);
                                traceFmt(opts, trace_start, "resume-staleness baseline = {d} assistant turn(s) before submit", .{baseline_turns});

                                // The prompt is in Ink's input box but NOT yet
                                // submitted. When an MCP-readiness sentinel was
                                // requested, hold the Enter until the bridged tool
                                // surface is live (the main loop polls the file and
                                // submits); otherwise submit immediately (legacy).
                                if (opts.mcp_ready_file) |rf| {
                                    mcp_ready_deadline_ns = std.time.nanoTimestamp() + @as(i128, @intCast(mcp_ready_max_wait_ms)) * std.time.ns_per_ms;
                                    traceFmt(opts, trace_start, "prompt echo confirmed; holding Enter for MCP readiness (file={s})", .{rf});
                                    state = .waiting_for_mcp_ready;
                                } else {
                                    std.Thread.sleep(ink_enter_debounce_ms * std.time.ns_per_ms);
                                    session.send("", true) catch {};
                                    trace(opts, trace_start, "prompt echo confirmed; Enter sent; waiting on claude API");
                                    state = .awaiting_stop;
                                }
                            }
                        },
                        .stop => {
                            if (transcript_path == null) {
                                transcript_path = try hook_mod.extractTranscriptPath(allocator, ev.payload);
                            }
                            // State gate: a Stop that arrives before we've submitted
                            // the live prompt is a replayed/prior-turn signal, not ours.
                            // Record the transcript path (above) but do not treat it as
                            // our turn's completion.
                            if (state != .awaiting_stop) {
                                trace(opts, trace_start, "ignoring Stop hook — live prompt not yet submitted (state gate)");
                            } else {
                                trace(opts, trace_start, "Stop hook fired (assistant turn finished)");
                                stop_payload_owned = try allocator.dupe(u8, ev.payload);
                            }
                        },
                        .unknown => {},
                    }
                }
                std.mem.copyForwards(u8, fifo_buf.items, fifo_buf.items[nl + 1 ..]);
                fifo_buf.shrinkRetainingCapacity(fifo_buf.items.len - (nl + 1));
                if (stop_payload_owned != null) break;
            }
        }

        // Open the tailer as soon as the transcript file shows up on disk.
        // claude writes `transcript_path` into the SessionStart payload
        // before it has actually created the file; we keep retrying so we
        // can start emitting from the very first line `claude` writes.
        if (streaming and tailer == null) {
            if (transcript_path) |p| {
                tailer_open_attempts += 1;
                if (stream_mod.Tailer.open(allocator, p)) |t| {
                    tailer = t;
                    traceFmt(opts, trace_start, "transcript opened for tailing after {d} attempt(s): {s}", .{ tailer_open_attempts, p });
                } else |e| switch (e) {
                    error.FileNotFound => {
                        // Expected; keep trying.
                        if (tailer_open_attempts == 1) {
                            traceFmt(opts, trace_start, "transcript not yet on disk; retrying (path={s})", .{p});
                        }
                    },
                    else => {
                        traceFmt(opts, trace_start, "transcript open failed: {s}", .{@errorName(e)});
                    },
                }
            }
        }

        // Pump any new transcript bytes to the caller's stream_writer.
        if (streaming and tailer != null and opts.stream_writer != null) {
            const n = tailer.?.pump(opts.stream_writer.?) catch 0;
            if (n > 0) {
                opts.stream_writer.?.flush() catch {};
                total_lines_streamed += n;
                if (!first_emit_logged) {
                    traceFmt(opts, trace_start, "first transcript line streamed ({d} line(s) in first flush)", .{n});
                    first_emit_logged = true;
                } else {
                    traceFmt(opts, trace_start, "streamed {d} more line(s) (total={d})", .{ n, total_lines_streamed });
                }
            }
        }

        if (stop_payload_owned != null) break;

        std.Thread.sleep(5 * std.time.ns_per_ms);
    }

    // Final pump — Claude flushes the last assistant message after Stop fires.
    if (streaming and opts.stream_writer != null) {
        trace(opts, trace_start, "draining post-Stop transcript flush window (20 × 20ms)");
        // The Stop event may have arrived before claude flushed the trailing
        // transcript line. If we haven't opened a Tailer yet (transcript_path
        // only arrived via Stop), do it now.
        if (tailer == null) {
            if (transcript_path) |p| tailer = stream_mod.Tailer.open(allocator, p) catch null;
        }
        if (tailer != null) {
            // Retry briefly to catch the final-flush window (same race the
            // parseFile fallback below handles).
            var attempt: u32 = 0;
            var post_stop_lines: usize = 0;
            while (attempt < 20) : (attempt += 1) {
                const n = tailer.?.pump(opts.stream_writer.?) catch 0;
                post_stop_lines += n;
                std.Thread.sleep(20 * std.time.ns_per_ms);
            }
            opts.stream_writer.?.flush() catch {};
            traceFmt(opts, trace_start, "post-Stop drain streamed {d} more line(s)", .{post_stop_lines});
        }
    }

    const tp = transcript_path orelse return RunError.TranscriptUnavailable;

    // ONE rule: the result is the LIVE turn or it is an error. The transcript
    // must have grown past the pre-submit baseline (a new assistant turn
    // appended) AND its text (or an error) must be present. The Stop hook can
    // fire a few ms before claude flushes the assistant line, so retry briefly.
    // If the live turn does not materialize in the transcript within the window
    // we FAIL (StopTimeout) — no Stop-payload fallback, no fresh-vs-resume
    // special-case: an error gives the caller visibility (it cold-retries),
    // rather than papering over a slow/absent write with a guessed answer.
    var summary = blk: {
        var attempt: u32 = 0;
        while (attempt < 40) : (attempt += 1) {
            var maybe = transcript_mod.parseFile(allocator, tp) catch |e| switch (e) {
                error.NoAssistantMessage, error.FileNotFound => null,
                else => return e,
            };
            if (maybe) |valid| {
                if (valid.num_turns > baseline_turns and (valid.final_text.len > 0 or valid.is_error)) {
                    break :blk valid;
                }
                maybe.?.deinit(allocator);
            }
            std.Thread.sleep(50 * std.time.ns_per_ms);
        }
        traceFmt(opts, trace_start, "resume-staleness guard: no live turn past baseline ({d}) within window — failing for visibility (StopTimeout)", .{baseline_turns});
        return RunError.StopTimeout;
    };
    errdefer summary.deinit(allocator);

    // Tear down the child immediately — we already have the answer.
    session.terminate();

    const total_ns: i128 = std.time.nanoTimestamp() - start_ns;
    const duration_ms: u64 = @intCast(@divTrunc(total_ns, std.time.ns_per_ms));

    // If we streamed transcript JSONL live, append the trailing `result`
    // envelope (the same final line `claude -p --output-format stream-json`
    // emits) so the wire format is complete.
    var streamed = false;
    if (streaming) {
        if (opts.stream_writer) |w| {
            try emit_mod.emitJson(allocator, w, .{
                .summary = &summary,
                .duration_ms = duration_ms,
            });
            w.flush() catch {};
            streamed = true;
            trace(opts, trace_start, "result envelope emitted; stream done");
        }
    }

    traceFmt(opts, trace_start, "run() returning (total_lines_streamed={d}, duration={d}ms)", .{ total_lines_streamed, duration_ms });
    return Result{
        .summary = summary,
        .duration_ms = duration_ms,
        .streamed = streamed,
    };
}

/// Strip CSI / OSC / DCS escape sequences, leaving only literal payload.
/// Used to make plain-text substring matching (e.g. trust-dialog detection)
/// robust against cursor-positioning escapes that pad words with `\033[1C`.
fn stripCsi(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < bytes.len) {
        const b = bytes[i];
        if (b != 0x1b) {
            try out.append(allocator, b);
            i += 1;
            continue;
        }
        if (i + 1 >= bytes.len) break;
        const next = bytes[i + 1];
        switch (next) {
            '[' => {
                i += 2;
                while (i < bytes.len and bytes[i] >= 0x30 and bytes[i] <= 0x3f) : (i += 1) {}
                while (i < bytes.len and bytes[i] >= 0x20 and bytes[i] <= 0x2f) : (i += 1) {}
                if (i < bytes.len) i += 1; // final byte
            },
            ']' => {
                i += 2;
                while (i < bytes.len) : (i += 1) {
                    if (bytes[i] == 0x07) {
                        i += 1;
                        break;
                    }
                    if (bytes[i] == 0x1b and i + 1 < bytes.len and bytes[i + 1] == '\\') {
                        i += 2;
                        break;
                    }
                }
            },
            'P', 'X', '^', '_' => {
                i += 2;
                while (i < bytes.len) : (i += 1) {
                    if (bytes[i] == 0x1b and i + 1 < bytes.len and bytes[i + 1] == '\\') {
                        i += 2;
                        break;
                    }
                }
            },
            else => {
                i += 2;
            },
        }
    }
    return try out.toOwnedSlice(allocator);
}

/// custom: copy only the ASCII alphanumeric bytes of `src` (drops spaces,
/// punctuation, and any residual control bytes). Used to compare the prompt
/// against its echo robustly across Ink's wrapping / CSI padding / spacing.
fn alnumCopy(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);
    for (src) |c| {
        if ((c >= '0' and c <= '9') or (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z')) {
            try out.append(allocator, c);
        }
    }
    return try out.toOwnedSlice(allocator);
}

/// custom: the marker Claude Code renders INSTEAD of echoing a large/multi-line
/// paste. Above a size/line threshold it collapses the input into placeholders
/// like "[Pasted text #1 +30 lines][Pasted text #2 +29 lines]" and never echoes
/// the literal text — so the needle below can never match for big prompts (e.g.
/// the bridge's bundled system prompt). The collapse is DISPLAY-ONLY: Enter
/// still submits the full content. So the placeholder's presence after we typed
/// is itself proof the input was accepted, and counts as echo confirmation.
const paste_collapse_marker = "Pasted text";

/// custom: does the typed prompt's echo (literal, or its paste-collapse
/// placeholder) appear in the recent PTY output? Pure, so it is unit-testable.
///   - `hay_alnum`: alnum-only projection of the CSI-stripped recent buffer
///   - `needle`:    alnum-only projection of the prompt's first echo_needle_max chars
///   - `stripped`:  CSI-stripped recent buffer, NOT alnum-projected (keeps the
///                  space in the `paste_collapse_marker`)
fn echoConfirms(hay_alnum: []const u8, needle: []const u8, stripped: []const u8) bool {
    if (needle.len == 0) return true; // nothing distinctive to confirm — don't block
    if (std.mem.indexOf(u8, hay_alnum, needle) != null) return true; // literal echo (small prompts)
    if (std.mem.indexOf(u8, stripped, paste_collapse_marker) != null) return true; // collapsed paste (large prompts)
    return false;
}

/// custom: has the typed prompt echoed back into the PTY output captured in
/// `recent`? Compares an alnum-only projection of both sides so spaces,
/// escapes, and line-wrapping inserted by Ink don't defeat the match; also
/// accepts Claude Code's paste-collapse placeholder (see echoConfirms). Returns
/// true when the prompt has no alnum content (nothing distinctive to confirm —
/// don't block such prompts).
fn promptEchoConfirmed(allocator: std.mem.Allocator, shared: *SharedState, prompt: []const u8) !bool {
    const needle_full = try alnumCopy(allocator, prompt);
    defer allocator.free(needle_full);
    if (needle_full.len == 0) return true;
    const needle = needle_full[0..@min(needle_full.len, echo_needle_max)];

    shared.recent_mutex.lock();
    const stripped = stripCsi(allocator, shared.recent.items) catch {
        shared.recent_mutex.unlock();
        return false;
    };
    shared.recent_mutex.unlock();
    defer allocator.free(stripped);

    const hay = try alnumCopy(allocator, stripped);
    defer allocator.free(hay);
    return echoConfirms(hay, needle, stripped);
}

// -------- tests --------

const testing = std.testing;

test "echoConfirms: literal echo matches (small prompt)" {
    // Needle (alnum of prompt start) appears in the alnum-projected hay.
    try testing.expect(echoConfirms("xxHELLOWORLDxx", "HELLOWORLD", "xx HELLO WORLD xx"));
}

test "echoConfirms: paste-collapse placeholder counts as confirmation" {
    // Large prompt: literal needle is ABSENT (Claude Code never echoes it), but
    // the "[Pasted text #N +M lines]" placeholder is present → accepted.
    const stripped = "\xe2\x9d\xaf [Pasted text #1 +30 lines][Pasted text #2 +29 lines]";
    try testing.expect(echoConfirms("someunrelatedchrome", "NEEDLESTARTabc", stripped));
}

test "echoConfirms: neither literal echo nor placeholder → not confirmed" {
    try testing.expect(!echoConfirms("unrelatedoutput", "NEEDLESTART", "just some prompt text here"));
}

test "echoConfirms: empty needle → confirmed (nothing distinctive to match)" {
    try testing.expect(echoConfirms("", "", ""));
}

test "buildArgv: minimal" {
    var argv = try buildArgv(testing.allocator, "/bin/claude", "{}", .{
        .prompt = "hi",
    });
    defer argv.deinit(testing.allocator);
    try testing.expectEqualStrings("/bin/claude", argv.items[0]);
    try testing.expectEqualStrings("--settings", argv.items[1]);
    try testing.expectEqualStrings("{}", argv.items[2]);
}

test "buildArgv: with model + verbose" {
    var argv = try buildArgv(testing.allocator, "claude", "{}", .{
        .prompt = "hi",
        .model = "opus",
        .verbose = true,
    });
    defer argv.deinit(testing.allocator);
    var saw_model = false;
    var saw_verbose = false;
    for (argv.items) |a| {
        if (std.mem.eql(u8, a, "--model")) saw_model = true;
        if (std.mem.eql(u8, a, "--verbose")) saw_verbose = true;
    }
    try testing.expect(saw_model);
    try testing.expect(saw_verbose);
}

test "buildArgv: dangerously-skip-permissions" {
    var argv = try buildArgv(testing.allocator, "claude", "{}", .{
        .prompt = "x",
        .skip_permissions = true,
    });
    defer argv.deinit(testing.allocator);
    var saw = false;
    for (argv.items) |a| {
        if (std.mem.eql(u8, a, "--dangerously-skip-permissions")) saw = true;
    }
    try testing.expect(saw);
}

test "buildArgv: passthrough extra args" {
    var argv = try buildArgv(testing.allocator, "claude", "{}", .{
        .prompt = "x",
        .extra_args = &.{ "--include-hook-events", "--bare" },
    });
    defer argv.deinit(testing.allocator);
    var saw_hook = false;
    var saw_bare = false;
    for (argv.items) |a| {
        if (std.mem.eql(u8, a, "--include-hook-events")) saw_hook = true;
        if (std.mem.eql(u8, a, "--bare")) saw_bare = true;
    }
    try testing.expect(saw_hook);
    try testing.expect(saw_bare);
}

test "buildArgv: system-prompt + permission-mode forwarded" {
    var argv = try buildArgv(testing.allocator, "claude", "{}", .{
        .prompt = "x",
        .system_prompt = "Be terse",
        .permission_mode = "acceptEdits",
        .disallowed_tools = "Bash(rm *)",
    });
    defer argv.deinit(testing.allocator);

    var saw_sysp = false;
    var saw_sysv = false;
    var saw_pm = false;
    var saw_pmv = false;
    var saw_dt = false;
    var saw_dtv = false;
    for (argv.items) |a| {
        if (std.mem.eql(u8, a, "--system-prompt")) saw_sysp = true;
        if (std.mem.eql(u8, a, "Be terse")) saw_sysv = true;
        if (std.mem.eql(u8, a, "--permission-mode")) saw_pm = true;
        if (std.mem.eql(u8, a, "acceptEdits")) saw_pmv = true;
        if (std.mem.eql(u8, a, "--disallowedTools")) saw_dt = true;
        if (std.mem.eql(u8, a, "Bash(rm *)")) saw_dtv = true;
    }
    try testing.expect(saw_sysp and saw_sysv);
    try testing.expect(saw_pm and saw_pmv);
    try testing.expect(saw_dt and saw_dtv);
}

test "buildArgv: add-dirs + mcp-configs emit each entry as a flag pair" {
    var argv = try buildArgv(testing.allocator, "claude", "{}", .{
        .prompt = "x",
        .add_dirs = &.{ "/a", "/b" },
        .mcp_configs = &.{"server.json"},
    });
    defer argv.deinit(testing.allocator);

    var add_count: u32 = 0;
    var mcp_count: u32 = 0;
    for (argv.items, 0..) |a, idx| {
        if (std.mem.eql(u8, a, "--add-dir")) {
            add_count += 1;
            try testing.expect(idx + 1 < argv.items.len);
        }
        if (std.mem.eql(u8, a, "--mcp-config")) mcp_count += 1;
    }
    try testing.expectEqual(@as(u32, 2), add_count);
    try testing.expectEqual(@as(u32, 1), mcp_count);
}

test "shellQuoteArgv: simple" {
    const q = try shellQuoteArgv(testing.allocator, &.{ "echo", "hi" });
    defer testing.allocator.free(q);
    try testing.expectEqualStrings("'echo' 'hi'", q);
}

test "shellQuoteArgv: embeds single-quote" {
    const q = try shellQuoteArgv(testing.allocator, &.{"can't"});
    defer testing.allocator.free(q);
    try testing.expectEqualStrings("'can'\\''t'", q);
}

test "shellQuoteArgv: json with double quotes survives" {
    const q = try shellQuoteArgv(testing.allocator, &.{ "claude", "--settings", "{\"hooks\":{}}" });
    defer testing.allocator.free(q);
    // Round-trip via sh -c
    try testing.expect(std.mem.indexOf(u8, q, "{\"hooks\":{}}") != null);
}

test "run: empty prompt rejected" {
    try testing.expectError(RunError.NoPromptSupplied, run(testing.allocator, .{ .prompt = "" }));
}
