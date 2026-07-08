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
    /// Wall-time cap in ms. 0 = unlimited (no cap); the cap check is skipped.
    /// Optional write-only mirror of raw PTY output bytes. When set, every
    /// byte read from the `claude` PTY output is appended to this file in
    /// arrival order (pure tee). Strictly observational: nothing is ever
    /// written back to the PTY on behalf of the mirror, and prompt-delivery
    /// behavior is identical whether the flag is present or absent. Open
    /// and write failures are non-fatal: mirroring is disabled for the rest
    /// of the turn with a single stderr note; exit code and stdout output
    /// are unaffected. (claude-p-fork.write-only-pty-output-mirror)
    mirror_file: ?[]const u8 = null,
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
    // custom: positive terminal/non-acceptance evidence proved the current
    // prompt was not accepted into the transcript. Missing echo evidence and
    // elapsed time alone do not produce this error.
    PromptNotAccepted,
    // custom: reserved for legacy callers; MCP readiness is now an event wait.
    McpNotReady,
    // custom: Claude Code wrote an API-error turn into the transcript and did
    // not fire Stop. Non-retryable errors and exhausted retry budgets fail fast
    // with the captured upstream text available via lastApiErrorMessage().
    ApiError,
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

/// How long to wait between sending the prompt bytes and sending Enter.
/// Ink's bracketed-paste heuristic merges back-to-back writes; without a
/// gap, `\r` lands in the input buffer instead of triggering submit. This is a
/// write-separation debounce, not a liveness timeout.
const ink_enter_debounce_ms: u64 = 120;

// PTY echo helpers remain for regression tests and diagnostics, but echo is no
// longer the authoritative submission-acceptance gate.
const echo_needle_max: usize = 48; // alnum chars of the prompt used as the echo needle

// --- custom (MCP-readiness gate) ---
// After the prompt paste completes we HOLD the submit Enter until the MCP shim's
// readiness sentinel (Options.mcp_ready_file) appears, so the turn never
// generates before the bridged `mcp__custom-tools__*` surface is live in
// `claude`. This is an event wait, not a liveness timeout.

// --- custom (API-error turn recovery) ---
// Claude Code can flush an API-error assistant transcript record plus trailing
// turn_duration without firing Stop. Detect that transcript-level terminal event
// and retry only bounded, transient upstream failures.
const api_error_retries_env = "CLAUDE_P_API_ERROR_RETRIES";
const api_error_retries_default: u32 = 3;
const api_error_backoff_base_ms: u64 = 250;
const api_error_message_max: usize = 1024;

var last_api_error_message: [api_error_message_max]u8 = undefined;
var last_api_error_message_len: usize = 0;

pub fn lastApiErrorMessage() []const u8 {
    return last_api_error_message[0..last_api_error_message_len];
}

fn clearLastApiErrorMessage() void {
    last_api_error_message_len = 0;
}

fn setLastApiErrorMessage(attempts: u32, text: []const u8) void {
    const plural = if (attempts == 1) "" else "s";
    const msg = std.fmt.bufPrint(
        &last_api_error_message,
        "claude API error after {d} attempt{s}: {s}",
        .{ attempts, plural, text },
    ) catch blk: {
        const text_max = @min(text.len, api_error_message_max / 2);
        break :blk std.fmt.bufPrint(
            &last_api_error_message,
            "claude API error after {d} attempt{s}: {s}...",
            .{ attempts, plural, text[0..text_max] },
        ) catch "claude API error";
    };
    last_api_error_message_len = msg.len;
}

fn apiErrorRetryLimitFromEnv() u32 {
    const raw = std.posix.getenv(api_error_retries_env) orelse return api_error_retries_default;
    return std.fmt.parseInt(u32, raw, 10) catch api_error_retries_default;
}

fn apiErrorBackoffMs(retries_done: u32) u64 {
    const factor: u64 = @intCast(@min(retries_done, 4));
    return api_error_backoff_base_ms * factor;
}

fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) break;
        }
        if (j == needle.len) return true;
    }
    return false;
}

fn isRetryableApiErrorText(text: []const u8) bool {
    const needles = [_][]const u8{
        "overloaded",
        "overload",
        "capacity",
        "http 529",
        "529",
        "rate limit",
        "rate-limit",
        "rate_limit",
        "429",
        "service unavailable",
        "503",
    };
    for (needles) |needle| {
        if (containsAsciiIgnoreCase(text, needle)) return true;
    }
    return false;
}

const ApiErrorRetryDecision = enum { retry, fail };

fn apiErrorRetryDecision(retryable: bool, retries_done: u32, max_retries: u32) ApiErrorRetryDecision {
    if (retryable and retries_done < max_retries) return .retry;
    return .fail;
}

const ApiErrorTurn = struct {
    text: []u8,
    retryable: bool,
    assistant_turns: u32,

    fn deinit(self: *ApiErrorTurn, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

fn jsonBool(obj: std.json.ObjectMap, key: []const u8) bool {
    const v = obj.get(key) orelse return false;
    return v == .bool and v.bool;
}

fn jsonStringEquals(obj: std.json.ObjectMap, key: []const u8, expected: []const u8) bool {
    const v = obj.get(key) orelse return false;
    return v == .string and std.mem.eql(u8, v.string, expected);
}

fn appendContentText(allocator: std.mem.Allocator, out: *std.ArrayList(u8), content: std.json.Value) !void {
    if (content != .array) return;
    for (content.array.items) |block| {
        if (block != .object) continue;
        const block_type = block.object.get("type") orelse continue;
        if (block_type != .string or !std.mem.eql(u8, block_type.string, "text")) continue;
        if (block.object.get("text")) |t| {
            if (t == .string) try out.appendSlice(allocator, t.string);
        }
    }
}

fn extractAssistantText(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ![]u8 {
    var text: std.ArrayList(u8) = .{};
    errdefer text.deinit(allocator);

    if (obj.get("content")) |content| try appendContentText(allocator, &text, content);
    if (obj.get("message")) |msg| {
        if (msg == .object) {
            if (msg.object.get("content")) |content| try appendContentText(allocator, &text, content);
        }
    }

    return try text.toOwnedSlice(allocator);
}

fn isApiErrorAssistant(obj: std.json.ObjectMap) bool {
    if (jsonBool(obj, "isApiErrorMessage")) return true;
    if (obj.get("message")) |msg| {
        if (msg == .object and jsonBool(msg.object, "isApiErrorMessage")) return true;
    }
    return false;
}

fn detectApiErrorTurnEnd(allocator: std.mem.Allocator, bytes: []const u8, baseline_turns: u32) !?ApiErrorTurn {
    var assistant_turns: u32 = 0;
    var pending_text: ?[]u8 = null;
    errdefer if (pending_text) |p| allocator.free(p);

    var line_iter = std.mem.splitScalar(u8, bytes, '\n');
    while (line_iter.next()) |raw_line| {
        var line = raw_line;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len == 0) continue;

        var parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            line,
            .{ .ignore_unknown_fields = true },
        ) catch continue;
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) continue;
        const obj = root.object;
        const ty = obj.get("type") orelse continue;
        if (ty != .string) continue;

        if (std.mem.eql(u8, ty.string, "assistant")) {
            assistant_turns += 1;
            if (pending_text) |p| allocator.free(p);
            pending_text = null;
            if (assistant_turns > baseline_turns and isApiErrorAssistant(obj)) {
                pending_text = try extractAssistantText(allocator, obj);
            }
        } else if (std.mem.eql(u8, ty.string, "system")) {
            if (jsonStringEquals(obj, "subtype", "turn_duration")) {
                if (pending_text) |p| {
                    pending_text = null;
                    return ApiErrorTurn{
                        .text = p,
                        .retryable = isRetryableApiErrorText(p),
                        .assistant_turns = assistant_turns,
                    };
                }
            }
        }
    }

    return null;
}

fn detectApiErrorTurnEndFile(allocator: std.mem.Allocator, path: []const u8, baseline_turns: u32) !?ApiErrorTurn {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const bytes = try file.readToEndAlloc(allocator, 64 * 1024 * 1024);
    defer allocator.free(bytes);
    return detectApiErrorTurnEnd(allocator, bytes, baseline_turns);
}

fn isUserRecordObject(obj: std.json.ObjectMap) bool {
    const ty = obj.get("type") orelse return false;
    return ty == .string and std.mem.eql(u8, ty.string, "user");
}

fn userPromptId(obj: std.json.ObjectMap) ?[]const u8 {
    const id = obj.get("promptId") orelse return null;
    if (id != .string or id.string.len == 0) return null;
    return id.string;
}

fn userRecordCount(allocator: std.mem.Allocator, bytes: []const u8) !u32 {
    var count: u32 = 0;
    var line_iter = std.mem.splitScalar(u8, bytes, '\n');
    while (line_iter.next()) |raw_line| {
        var line = raw_line;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len == 0) continue;

        var parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            line,
            .{ .ignore_unknown_fields = true },
        ) catch continue;
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) continue;
        if (isUserRecordObject(root.object)) count += 1;
    }
    return count;
}

fn clearPromptIds(allocator: std.mem.Allocator, prompt_ids: *std.StringHashMap(void)) void {
    var key_it = prompt_ids.keyIterator();
    while (key_it.next()) |key| allocator.free(key.*);
    prompt_ids.clearRetainingCapacity();
}

fn collectUserPromptIds(allocator: std.mem.Allocator, bytes: []const u8, prompt_ids: *std.StringHashMap(void)) !u32 {
    var count: u32 = 0;
    var line_iter = std.mem.splitScalar(u8, bytes, '\n');
    while (line_iter.next()) |raw_line| {
        var line = raw_line;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len == 0) continue;

        var parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            line,
            .{ .ignore_unknown_fields = true },
        ) catch continue;
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) continue;
        const obj = root.object;
        if (!isUserRecordObject(obj)) continue;
        count += 1;
        if (userPromptId(obj)) |pid| {
            if (!prompt_ids.contains(pid)) {
                const owned = try allocator.dupe(u8, pid);
                errdefer allocator.free(owned);
                try prompt_ids.put(owned, {});
            }
        }
    }
    return count;
}

fn hasNewUserPromptId(allocator: std.mem.Allocator, bytes: []const u8, baseline: TranscriptUserBaseline, prompt_ids: *std.StringHashMap(void)) !bool {
    var line_iter = std.mem.splitScalar(u8, bytes, '\n');
    while (line_iter.next()) |raw_line| {
        var line = raw_line;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len == 0) continue;

        var parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            line,
            .{ .ignore_unknown_fields = true },
        ) catch continue;
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) continue;
        const obj = root.object;
        if (!isUserRecordObject(obj)) continue;
        const pid = userPromptId(obj) orelse {
            if (baseline.allow_promptless_user) return true;
            continue;
        };
        if (!prompt_ids.contains(pid)) return true;
    }
    return false;
}

const TranscriptUserBaseline = struct {
    file_existed: bool = false,
    bytes_len: u64 = 0,
    user_records: u32 = 0,
    allow_promptless_user: bool = false,
};

fn transcriptUserBaseline(allocator: std.mem.Allocator, bytes: []const u8, prompt_ids: *std.StringHashMap(void)) !TranscriptUserBaseline {
    return .{
        .file_existed = true,
        .bytes_len = bytes.len,
        .user_records = try collectUserPromptIds(allocator, bytes, prompt_ids),
    };
}

fn transcriptUserBaselineFile(allocator: std.mem.Allocator, path: ?[]const u8, prompt_ids: *std.StringHashMap(void)) TranscriptUserBaseline {
    clearPromptIds(allocator, prompt_ids);
    const p = path orelse return .{};
    const file = std.fs.cwd().openFile(p, .{}) catch return .{};
    defer file.close();
    const bytes = file.readToEndAlloc(allocator, 64 * 1024 * 1024) catch return .{};
    defer allocator.free(bytes);
    return transcriptUserBaseline(allocator, bytes, prompt_ids) catch .{};
}

fn transcriptHasNewUserRecord(allocator: std.mem.Allocator, path: ?[]const u8, baseline: TranscriptUserBaseline, prompt_ids: *std.StringHashMap(void)) bool {
    const p = path orelse return false;
    const file = std.fs.cwd().openFile(p, .{}) catch return false;
    defer file.close();
    const bytes = file.readToEndAlloc(allocator, 64 * 1024 * 1024) catch return false;
    defer allocator.free(bytes);
    return hasNewUserPromptId(allocator, bytes, baseline, prompt_ids) catch false;
}

fn captureTranscriptUserBaseline(
    allocator: std.mem.Allocator,
    opts: Options,
    trace_start: i128,
    path: ?[]const u8,
    prompt_ids: *std.StringHashMap(void),
) RunError!TranscriptUserBaseline {
    var baseline = transcriptUserBaselineFile(allocator, path, prompt_ids);
    const fresh_prompt_turn = opts.resume_session == null and !opts.cont and opts.session_id == null;
    if (!fresh_prompt_turn and !baseline.file_existed) {
        trace(opts, trace_start, "non-fresh transcript baseline unavailable before submit — failing closed");
        return RunError.TranscriptUnavailable;
    }
    baseline.allow_promptless_user = fresh_prompt_turn and baseline.user_records == 0;
    traceFmt(opts, trace_start, "transcript user baseline captured: existed={}, bytes={d}, user_records={d}, allow_promptless={}", .{ baseline.file_existed, baseline.bytes_len, baseline.user_records, baseline.allow_promptless_user });
    return baseline;
}

fn waitForTranscriptUserRecord(
    allocator: std.mem.Allocator,
    opts: Options,
    trace_start: i128,
    shared: *SharedState,
    session: anytype,
    path: ?[]const u8,
    baseline: TranscriptUserBaseline,
    prompt_ids: *std.StringHashMap(void),
) RunError!void {
    while (true) {
        try flushPendingToPty(allocator, shared, session);
        if (transcriptHasNewUserRecord(allocator, path, baseline, prompt_ids)) {
            trace(opts, trace_start, "transcript user-record acceptance confirmed");
            return;
        }
        if (shared.exited.load(.seq_cst)) return RunError.PromptNotAccepted;
        std.Thread.sleep(15 * std.time.ns_per_ms);
    }
}

fn clearRecent(shared: *SharedState) void {
    shared.recent_mutex.lock();
    shared.recent.clearRetainingCapacity();
    shared.recent_mutex.unlock();
}

fn flushPendingToPty(allocator: std.mem.Allocator, shared: *SharedState, session: anytype) !void {
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
}

/// True if an absolute path exists and is accessible. Used to poll for the
/// MCP-readiness sentinel without blocking the main loop.
fn fileExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

const bracketed_paste_enable = "\x1b[?2004h";
const bracketed_paste_start = "\x1b[200~";
const bracketed_paste_end = "\x1b[201~";

fn inputReadyFromPty(bytes: []const u8) bool {
    return std.mem.indexOf(u8, bytes, bracketed_paste_enable) != null;
}

/// Block until the host TUI emits the bracketed-paste-enable sentinel. This is
/// an event wait, not a liveness timeout: the driver never "types anyway" based
/// on elapsed time. If the child exits before readiness, surface the terminal
/// spawn failure instead of racing a dead input surface.
fn waitForInputReadiness(allocator: std.mem.Allocator, opts: Options, trace_start: i128, shared: *SharedState, session: anytype) RunError!void {
    while (true) {
        try flushPendingToPty(allocator, shared, session);
        if (shared.input_ready.load(.seq_cst)) {
            trace(opts, trace_start, "input readiness confirmed (ESC[?2004h seen)");
            return;
        }
        if (shared.exited.load(.seq_cst)) return RunError.SpawnFailed;
        std.Thread.sleep(15 * std.time.ns_per_ms);
    }
}

fn appendBracketedPaste(allocator: std.mem.Allocator, out: *std.ArrayList(u8), prompt: []const u8) !void {
    try out.appendSlice(allocator, bracketed_paste_start);
    try out.appendSlice(allocator, prompt);
    try out.appendSlice(allocator, bracketed_paste_end);
}

fn writeBracketedPaste(session: anytype, prompt: []const u8) !void {
    try session.writeInput(bracketed_paste_start);
    try session.writeInput(prompt);
    try session.writeInput(bracketed_paste_end);
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
    input_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    // Rolling buffer of recently-seen output. The driver loop scans this
    // for the workspace-trust dialog (shown in unfamiliar directories,
    // not bypassed by --dangerously-skip-permissions) and dismisses it
    // by pressing Enter.
    recent_mutex: std.Thread.Mutex = .{},
    recent: std.ArrayList(u8) = .{},
    trust_dismissed: bool = false,
    // Write-only PTY output mirror (claude-p-fork.write-only-pty-output-mirror).
    // Touched only by the reader thread (pane_output events are serialized),
    // so no mutex is needed. `mirror_failed` latches on first error; a single
    // stderr note is emitted at latch time and the turn proceeds unaffected.
    mirror_path: ?[]const u8 = null,
    mirror_file: ?std.fs.File = null,
    mirror_failed: bool = false,
};

/// Append one PTY output chunk to the mirror file (pure tee; arrival order).
/// Lazy-opens on the first chunk. All failures are non-fatal: latch
/// `mirror_failed`, note once on stderr, never affect the turn.
fn mirrorChunk(shared: *SharedState, data: []const u8) void {
    if (shared.mirror_failed) return;
    const path = shared.mirror_path orelse return;
    if (shared.mirror_file == null) {
        shared.mirror_file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch {
            shared.mirror_failed = true;
            std.debug.print("claude-p: --mirror-file open failed ({s}); mirroring disabled for this turn\n", .{path});
            return;
        };
    }
    shared.mirror_file.?.writeAll(data) catch {
        shared.mirror_failed = true;
        if (shared.mirror_file) |f| f.close();
        shared.mirror_file = null;
        std.debug.print("claude-p: --mirror-file write failed; mirroring disabled for this turn\n", .{});
    };
}

const recent_capacity: usize = 8192;

fn onZmuxEvent(ctx: *anyopaque, event: zmux.native.Event) void {
    const shared: *SharedState = @ptrCast(@alignCast(ctx));
    switch (event) {
        .pane_output => |po| {
            _ = shared.bytes_seen.fetchAdd(po.data.len, .seq_cst);
            mirrorChunk(shared, po.data);
            if (inputReadyFromPty(po.data)) shared.input_ready.store(true, .seq_cst);
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
            if (!shared.input_ready.load(.seq_cst) and inputReadyFromPty(shared.recent.items)) {
                shared.input_ready.store(true, .seq_cst);
            }
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
    clearLastApiErrorMessage();

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
        .mirror_path = opts.mirror_file,
    };
    defer {
        shared.write_mutex.lock();
        shared.pending_to_pty.deinit(std.heap.page_allocator);
        shared.write_mutex.unlock();
        shared.recent_mutex.lock();
        shared.recent.deinit(std.heap.page_allocator);
        shared.recent_mutex.unlock();
        if (shared.mirror_file) |f| f.close();
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
    // Prompt-acceptance baseline: the number of user records already in the
    // transcript BEFORE the live prompt is submitted. The live prompt is
    // accepted only when the active transcript gains another user record.
    var baseline_user_record: TranscriptUserBaseline = .{};
    var baseline_user_prompt_ids = std.StringHashMap(void).init(allocator);
    defer baseline_user_prompt_ids.deinit();
    defer clearPromptIds(allocator, &baseline_user_prompt_ids);
    // Resume BILLING baseline: the deduped usage already in the transcript before
    // submit. The final result's usage is the post-turn deduped total MINUS this,
    // so result.usage reflects only the live turn (mirroring `claude -p`, which
    // bills the invocation — not the replayed history). Captured at echo-confirm.
    var baseline_usage: transcript_mod.Usage = .{};

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

    const api_error_retry_limit = apiErrorRetryLimitFromEnv();
    var api_error_retries_done: u32 = 0;

    while (true) {
        if (shared.exited.load(.seq_cst) and
            (state == .waiting_for_ready or state == .waiting_for_mcp_ready))
        {
            return RunError.SpawnFailed;
        }

        // MCP-readiness gate: the prompt paste has completed; we hold submit
        // Enter until the shim's sentinel appears. This is an event wait (like
        // the readiness and transcript gates), not a liveness timeout.
        if (state == .waiting_for_mcp_ready) {
            if (opts.mcp_ready_file) |rf| {
                if (fileExists(rf)) {
                    std.Thread.sleep(ink_enter_debounce_ms * std.time.ns_per_ms);
                    session.send("", true) catch {};
                    trace(opts, trace_start, "MCP surface ready; Enter sent; waiting for transcript user-record acceptance");
                    try waitForTranscriptUserRecord(allocator, opts, trace_start, &shared, session, transcript_path, baseline_user_record, &baseline_user_prompt_ids);
                    trace(opts, trace_start, "transcript accepted prompt; waiting on claude API");
                    state = .awaiting_stop;
                }
            }
        }

        // Flush any DEC-responder bytes back to the PTY.
        try flushPendingToPty(allocator, &shared, session);

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
                            if (transcript_path == null) {
                                if (try hook_mod.extractTranscriptPath(allocator, ev.payload)) |p| {
                                    transcript_path = p;
                                    traceFmt(opts, trace_start, "transcript_path from SessionStart: {s}", .{p});
                                }
                            }
                            if (state == .waiting_for_ready) {
                                // Wait for the host input surface itself, not
                                // a quiescence timer. `ESC[?2004h` means Claude
                                // Code has enabled bracketed paste for the live
                                // prompt box; until then, prompt bytes can be
                                // dropped by the not-yet-ready TUI.
                                try waitForInputReadiness(allocator, opts, trace_start, &shared, session);

                                traceFmt(opts, trace_start, "pasting prompt ({d} bytes)", .{opts.prompt.len});
                                writeBracketedPaste(session, opts.prompt) catch {};

                                // Snapshot baselines after paste delivery but before
                                // submit Enter. The transcript still ends at the prior
                                // turn; the live prompt must create a new user record
                                // before any assistant Stop/result is trusted.
                                baseline_turns = transcript_mod.turnCountFile(allocator, transcript_path);
                                baseline_user_record = try captureTranscriptUserBaseline(allocator, opts, trace_start, transcript_path, &baseline_user_prompt_ids);
                                baseline_usage = transcript_mod.usageFile(allocator, transcript_path);
                                traceFmt(opts, trace_start, "submit baselines before Enter: assistant_turns={d}, user_records={d}, bytes={d}", .{ baseline_turns, baseline_user_record.user_records, baseline_user_record.bytes_len });

                                if (opts.mcp_ready_file) |rf| {
                                    traceFmt(opts, trace_start, "prompt pasted; holding Enter for MCP readiness (file={s})", .{rf});
                                    state = .waiting_for_mcp_ready;
                                } else {
                                    std.Thread.sleep(ink_enter_debounce_ms * std.time.ns_per_ms);
                                    session.send("", true) catch {};
                                    trace(opts, trace_start, "Enter sent; waiting for transcript user-record acceptance");
                                    try waitForTranscriptUserRecord(allocator, opts, trace_start, &shared, session, transcript_path, baseline_user_record, &baseline_user_prompt_ids);
                                    trace(opts, trace_start, "transcript accepted prompt; waiting on claude API");
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

        // API-error turn-end detection: Claude Code can finish a turn by
        // flushing an isApiErrorMessage assistant record plus turn_duration
        // without firing Stop. Poll the transcript once known, even when the
        // caller did not request stream-json tailing.
        if (state == .awaiting_stop and stop_payload_owned == null) {
            if (transcript_path) |p| {
                var api_turn = detectApiErrorTurnEndFile(allocator, p, baseline_turns) catch |e| switch (e) {
                    error.FileNotFound => null,
                    else => return e,
                };
                if (api_turn) |*turn| {
                    defer turn.deinit(allocator);
                    const failed_attempts = api_error_retries_done + 1;
                    if (apiErrorRetryDecision(turn.retryable, api_error_retries_done, api_error_retry_limit) == .retry) {
                        api_error_retries_done += 1;
                        const backoff_ms = apiErrorBackoffMs(api_error_retries_done);
                        traceFmt(
                            opts,
                            trace_start,
                            "API-error turn confirmed after {d} attempt(s): {s}; retry {d}/{d} after {d}ms",
                            .{ failed_attempts, turn.text, api_error_retries_done, api_error_retry_limit, backoff_ms },
                        );
                        std.Thread.sleep(backoff_ms * std.time.ns_per_ms);

                        baseline_turns = transcript_mod.turnCountFile(allocator, transcript_path);
                        baseline_user_record = try captureTranscriptUserBaseline(allocator, opts, trace_start, transcript_path, &baseline_user_prompt_ids);
                        baseline_usage = transcript_mod.usageFile(allocator, transcript_path);
                        traceFmt(opts, trace_start, "submit baselines reset after API error: assistant_turns={d}, user_records={d}, bytes={d}", .{ baseline_turns, baseline_user_record.user_records, baseline_user_record.bytes_len });

                        traceFmt(opts, trace_start, "repasting prompt after API error ({d} bytes)", .{opts.prompt.len});
                        writeBracketedPaste(session, opts.prompt) catch {};

                        std.Thread.sleep(ink_enter_debounce_ms * std.time.ns_per_ms);
                        session.send("", true) catch {};
                        trace(opts, trace_start, "retry Enter sent; waiting for transcript user-record acceptance");
                        try waitForTranscriptUserRecord(allocator, opts, trace_start, &shared, session, transcript_path, baseline_user_record, &baseline_user_prompt_ids);
                        trace(opts, trace_start, "transcript accepted retry prompt; waiting on claude API");
                    } else {
                        setLastApiErrorMessage(failed_attempts, turn.text);
                        traceFmt(opts, trace_start, "API-error turn failed fast: {s}", .{lastApiErrorMessage()});
                        session.terminate();
                        return RunError.ApiError;
                    }
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

    // Bill only the LIVE turn: `summary.usage` is the deduped total over the whole
    // transcript (history + live); subtract the deduped baseline captured at submit.
    // Saturating (`-|`) guards the degenerate case where the baseline somehow
    // exceeds the post-turn total (e.g. a mid-turn transcript rewrite).
    summary.usage = .{
        .input_tokens = summary.usage.input_tokens -| baseline_usage.input_tokens,
        .output_tokens = summary.usage.output_tokens -| baseline_usage.output_tokens,
        .cache_read_input_tokens = summary.usage.cache_read_input_tokens -| baseline_usage.cache_read_input_tokens,
        .cache_creation_input_tokens = summary.usage.cache_creation_input_tokens -| baseline_usage.cache_creation_input_tokens,
    };

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

/// custom: markers Claude Code renders INSTEAD of echoing a large/multi-line
/// paste. Above a size/line threshold it collapses the input into placeholders
/// like "[Pasted text #1 +30 lines]" and never echoes the literal text — so the
/// needle below can never match for big prompts (e.g. the bridge's bundled
/// system prompt). Ink can split the marker with cursor-position CSI escapes,
/// producing a stripped projection like "Pastedtext#1" with no literal space.
/// The collapse is DISPLAY-ONLY: Enter still submits the full content. So the
/// placeholder's presence after we typed is itself proof the input was accepted,
/// and counts as echo confirmation.
const paste_collapse_marker_alnum = "Pastedtext";
const paste_collapse_hint = "paste again to expand";

/// custom: does the typed prompt's echo (literal, or its paste-collapse
/// placeholder) appear in the recent PTY output? Pure, so it is unit-testable.
///   - `hay_alnum`: alnum-only projection of the CSI-stripped recent buffer
///   - `needle`:    alnum-only projection of the prompt's first echo_needle_max chars
///   - `stripped`:  CSI-stripped recent buffer, NOT alnum-projected (keeps
///                  spaces for the paste-collapse hint phrase)
fn echoConfirms(hay_alnum: []const u8, needle: []const u8, stripped: []const u8) bool {
    if (needle.len == 0) return true; // nothing distinctive to confirm — don't block
    if (std.mem.indexOf(u8, hay_alnum, needle) != null) return true; // literal echo (small prompts)
    if (std.mem.indexOf(u8, hay_alnum, paste_collapse_marker_alnum) != null) return true; // collapsed paste marker, whitespace/control-normalized
    if (std.mem.indexOf(u8, stripped, paste_collapse_hint) != null) return true; // collapsed paste hint (large prompts)
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

test "input readiness requires bracketed-paste enable sentinel" {
    // AC: prompt-echo-confirmation.prompt-delivery-readiness-is-event-gated
    try testing.expect(!inputReadyFromPty("booting..."));
    try testing.expect(!inputReadyFromPty("\x1b[?20"));
    try testing.expect(inputReadyFromPty("booting...\x1b[?2004hready"));
    try testing.expect(inputReadyFromPty("\x1b[?20" ++ "04h"));
}

test "appendBracketedPaste frames prompt before separate Enter" {
    // AC: prompt-echo-confirmation.prompt-delivery-uses-bracketed-paste
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(testing.allocator);
    try appendBracketedPaste(testing.allocator, &out, "hello\nworld");
    try testing.expectEqualStrings("\x1b[200~hello\nworld\x1b[201~", out.items);
    try testing.expect(std.mem.indexOf(u8, out.items, "\r") == null);
}

test "non-fresh missing transcript baseline fails closed" {
    // AC: prompt-echo-confirmation.replayed-history-does-not-confirm-submission
    var prompt_ids = std.StringHashMap(void).init(testing.allocator);
    defer prompt_ids.deinit();
    defer clearPromptIds(testing.allocator, &prompt_ids);
    try testing.expectError(
        RunError.TranscriptUnavailable,
        captureTranscriptUserBaseline(
            testing.allocator,
            .{ .prompt = "x", .resume_session = "sid" },
            0,
            null,
            &prompt_ids,
        ),
    );
}

test "missing transcript baseline does not block fresh-session acceptance" {
    // AC: prompt-echo-confirmation.transcript-user-record-confirms-submission
    const baseline: TranscriptUserBaseline = .{ .allow_promptless_user = true };
    try testing.expect(!baseline.file_existed);
    const first_write =
        \\{"type":"user","sessionId":"s","message":{"content":[{"type":"text","text":"fresh"}]}}
        \\
    ;
    try testing.expect((try userRecordCount(testing.allocator, first_write[baseline.bytes_len..])) > 0);
}

test "transcript baseline accepts only user records after baseline offset" {
    // AC: prompt-echo-confirmation.transcript-user-record-confirms-submission
    const before =
        \\{"promptId":"p1","type":"user","sessionId":"s","message":{"content":[{"type":"text","text":"prior"}]}}
        \\{"type":"assistant","sessionId":"s","message":{"content":[{"type":"text","text":"old"}]}}
        \\
    ;
    const after =
        \\{"promptId":"p1","type":"user","sessionId":"s","message":{"content":[{"type":"text","text":"prior"}]}}
        \\{"type":"assistant","sessionId":"s","message":{"content":[{"type":"text","text":"old"}]}}
        \\{"promptId":"p2","type":"user","sessionId":"s","message":{"content":[{"type":"text","text":"live"}]}}
        \\
    ;
    var prompt_ids = std.StringHashMap(void).init(testing.allocator);
    defer prompt_ids.deinit();
    defer clearPromptIds(testing.allocator, &prompt_ids);
    const baseline = try transcriptUserBaseline(testing.allocator, before, &prompt_ids);
    try testing.expectEqual(@as(u32, 1), baseline.user_records);
    try testing.expect(prompt_ids.contains("p1"));
    try testing.expectEqual(@as(u64, before.len), baseline.bytes_len);
    try testing.expectEqual(baseline.user_records, try userRecordCount(testing.allocator, after[0..baseline.bytes_len]));
    try testing.expect(try hasNewUserPromptId(testing.allocator, after[baseline.bytes_len..], baseline, &prompt_ids));
}

test "promptId-less user record is ignored unless fresh promptless acceptance is allowed" {
    // AC: prompt-echo-confirmation.replayed-history-does-not-confirm-submission
    const promptless =
        \\{"type":"user","sessionId":"s","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}
        \\
    ;
    var prompt_ids = std.StringHashMap(void).init(testing.allocator);
    defer prompt_ids.deinit();
    defer clearPromptIds(testing.allocator, &prompt_ids);
    try testing.expect(!(try hasNewUserPromptId(testing.allocator, promptless, .{}, &prompt_ids)));
    try testing.expect(try hasNewUserPromptId(testing.allocator, promptless, .{ .allow_promptless_user = true }, &prompt_ids));
}

test "promptId-less warm-resume tool result does not hide later live prompt" {
    // AC: prompt-echo-confirmation.transcript-user-record-confirms-submission
    const before =
        \\{"promptId":"p1","type":"user","sessionId":"s","message":{"content":[{"type":"text","text":"prior"}]}}
        \\{"type":"assistant","sessionId":"s","message":{"content":[{"type":"tool_use","id":"t1","name":"x"}]}}
        \\
    ;
    const after = before ++
        \\{"type":"user","sessionId":"s","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}
        \\{"promptId":"p2","type":"user","sessionId":"s","message":{"content":[{"type":"text","text":"live"}]}}
        \\
    ;
    var prompt_ids = std.StringHashMap(void).init(testing.allocator);
    defer prompt_ids.deinit();
    defer clearPromptIds(testing.allocator, &prompt_ids);
    const baseline = try transcriptUserBaseline(testing.allocator, before, &prompt_ids);
    try testing.expect(!baseline.allow_promptless_user);
    try testing.expect(try hasNewUserPromptId(testing.allocator, after, baseline, &prompt_ids));
}

test "replayed echo or paste marker does not confirm without transcript user record" {
    // AC: prompt-echo-confirmation.replayed-history-does-not-confirm-submission
    const replayed_pty = "what is 2+2? [Pasted\x1b[11Gtext\x1b[16G#1] paste again to expand";
    const stripped = try stripCsi(testing.allocator, replayed_pty);
    defer testing.allocator.free(stripped);
    const hay = try alnumCopy(testing.allocator, stripped);
    defer testing.allocator.free(hay);
    try testing.expect(echoConfirms(hay, "WHATIS22", stripped));

    const transcript =
        \\{"promptId":"same","type":"user","sessionId":"s","message":{"content":[{"type":"text","text":"what is 2+2?"}]}}
        \\{"type":"assistant","sessionId":"s","message":{"content":[{"type":"text","text":"4"}]}}
        \\
    ;
    var prompt_ids = std.StringHashMap(void).init(testing.allocator);
    defer prompt_ids.deinit();
    defer clearPromptIds(testing.allocator, &prompt_ids);
    const baseline = try transcriptUserBaseline(testing.allocator, transcript, &prompt_ids);
    try testing.expectEqual(@as(u32, 1), baseline.user_records);
    try testing.expect(!try hasNewUserPromptId(testing.allocator, transcript, baseline, &prompt_ids));
}

test "submission acceptance has no elapsed-time or echo-window failure path" {
    // AC: prompt-echo-confirmation.submission-handshake-has-no-liveness-timeout
    // AC: prompt-echo-confirmation.prompt-not-accepted-is-positive-signal-only
    const source = try std.fs.cwd().readFileAlloc(testing.allocator, "src/driver.zig", 1024 * 1024);
    defer testing.allocator.free(source);
    const stale_echo_clock = "echo_wait" ++ "_start";
    const stale_echo_failure = "prompt echo" ++ " never confirmed";
    const stale_mcp_deadline = "mcp_ready" ++ "_deadline";
    const stale_type_anyway = "typing" ++ " anyway";
    try testing.expect(std.mem.indexOf(u8, source, stale_echo_clock) == null);
    try testing.expect(std.mem.indexOf(u8, source, stale_echo_failure) == null);
    try testing.expect(std.mem.indexOf(u8, source, stale_mcp_deadline) == null);
    try testing.expect(std.mem.indexOf(u8, source, stale_type_anyway) == null);
}

test "api error detector: overloaded turn after baseline is terminal and retryable" {
    // AC: api-error-turns.transcript-api-error-ends-turn
    // AC: api-error-turns.retryable-api-errors-are-resubmitted-boundedly
    const jsonl =
        \\{"type":"assistant","session_id":"s","message":{"content":[{"type":"text","text":"prior"}]}}
        \\{"type":"user","session_id":"s","message":{"content":[{"type":"text","text":"live"}]}}
        \\{"type":"assistant","session_id":"s","isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"API Error: Overloaded"}]}}
        \\{"type":"system","subtype":"turn_duration","session_id":"s","durationMs":123,"messageCount":2}
        \\
    ;
    var turn = (try detectApiErrorTurnEnd(testing.allocator, jsonl, 1)).?;
    defer turn.deinit(testing.allocator);
    try testing.expectEqualStrings("API Error: Overloaded", turn.text);
    try testing.expect(turn.retryable);
    try testing.expectEqual(@as(u32, 2), turn.assistant_turns);
}

test "api error classifier: non-retryable auth error fails" {
    // AC: api-error-turns.non-retryable-api-errors-fail-fast
    const jsonl =
        \\{"type":"assistant","session_id":"s","isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"API Error: invalid x-api-key"}]}}
        \\{"type":"system","subtype":"turn_duration","session_id":"s","durationMs":123,"messageCount":1}
        \\
    ;
    var turn = (try detectApiErrorTurnEnd(testing.allocator, jsonl, 0)).?;
    defer turn.deinit(testing.allocator);
    try testing.expectEqualStrings("API Error: invalid x-api-key", turn.text);
    try testing.expect(!turn.retryable);
    try testing.expectEqual(ApiErrorRetryDecision.fail, apiErrorRetryDecision(turn.retryable, 0, api_error_retries_default));
}

test "api error detector: normal assistant turn is not api error" {
    // AC: api-error-turns.normal-assistant-turns-are-not-api-errors
    const jsonl =
        \\{"type":"assistant","session_id":"s","message":{"content":[{"type":"text","text":"normal answer"}]}}
        \\{"type":"system","subtype":"turn_duration","session_id":"s","durationMs":123,"messageCount":1}
        \\
    ;
    try testing.expect((try detectApiErrorTurnEnd(testing.allocator, jsonl, 0)) == null);
}

test "api error retry boundary: exhausted retry budget fails" {
    // AC: api-error-turns.exhausted-api-error-retries-fail-fast
    try testing.expectEqual(ApiErrorRetryDecision.retry, apiErrorRetryDecision(true, 2, 3));
    try testing.expectEqual(ApiErrorRetryDecision.fail, apiErrorRetryDecision(true, 3, 3));
    try testing.expectEqual(ApiErrorRetryDecision.fail, apiErrorRetryDecision(false, 0, 3));
}

test "echoConfirms: literal echo matches (small prompt)" {
    // AC: prompt-echo-confirmation.literal-prompt-echo-confirms-submission
    // Needle (alnum of prompt start) appears in the alnum-projected hay.
    try testing.expect(echoConfirms("xxHELLOWORLDxx", "HELLOWORLD", "xx HELLO WORLD xx"));
}

test "echoConfirms: paste-collapse placeholder counts as confirmation" {
    // AC: prompt-echo-confirmation.collapsed-paste-placeholder-confirms-submission
    // Large prompt: literal needle is ABSENT (Claude Code never echoes it), but
    // the "[Pasted text #N +M lines]" placeholder is present → accepted.
    const stripped = "\xe2\x9d\xaf [Pasted text #1 +30 lines][Pasted text #2 +29 lines]";
    const hay = try alnumCopy(testing.allocator, stripped);
    defer testing.allocator.free(hay);
    try testing.expect(echoConfirms(hay, "NEEDLESTARTabc", stripped));
}

test "echoConfirms: captured CSI-split paste-collapse marker confirms" {
    // AC: prompt-echo-confirmation.collapsed-paste-placeholder-confirms-submission
    // Captured from raw-ink-E801: Ink writes "Pasted", moves the cursor with
    // CSI, writes "text", moves again, then writes "#1]" and the expansion hint.
    const raw = "[Pasted\x1b[11Gtext\x1b[16G#1]\x1b[7m \r\x1b[2C\x1b[2B\x1b[27m\x1b[38;5;246mpaste again to expand\x1b[39m";
    const stripped = try stripCsi(testing.allocator, raw);
    defer testing.allocator.free(stripped);
    const hay = try alnumCopy(testing.allocator, stripped);
    defer testing.allocator.free(hay);

    try testing.expectEqualStrings("[Pastedtext#1] \rpaste again to expand", stripped);
    try testing.expect(echoConfirms(hay, "NEEDLESTARTabc", stripped));
}

test "echoConfirms: neither literal echo nor placeholder → not confirmed" {
    // AC: prompt-echo-confirmation.unrelated-output-does-not-confirm-submission
    // AC: prompt-echo-confirmation.prompt-not-accepted-remains-fail-fast
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

test "mirrorChunk: pure tee in arrival order (claude-p-fork.write-only-pty-output-mirror)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);
    const mirror_path = try std.fs.path.join(std.testing.allocator, &.{ path, "m.raw" });
    defer std.testing.allocator.free(mirror_path);

    var shared: SharedState = .{ .session = undefined, .debug = false, .mirror_path = mirror_path };
    mirrorChunk(&shared, "\x1b[2Jhello ");
    mirrorChunk(&shared, "world");
    if (shared.mirror_file) |f| f.close();

    const got = try std.fs.cwd().readFileAlloc(std.testing.allocator, mirror_path, 1 << 20);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("\x1b[2Jhello world", got);
}

test "mirrorChunk: absent path writes nothing" {
    var shared: SharedState = .{ .session = undefined, .debug = false };
    mirrorChunk(&shared, "data");
    try std.testing.expectEqual(@as(?std.fs.File, null), shared.mirror_file);
    try std.testing.expect(!shared.mirror_failed);
}

test "mirrorChunk: unwritable path latches non-fatally" {
    var shared: SharedState = .{
        .session = undefined,
        .debug = false,
        .mirror_path = "/nonexistent-dir-claude-p-test/m.raw",
    };
    mirrorChunk(&shared, "data");
    try std.testing.expect(shared.mirror_failed);
    // Subsequent chunks are no-ops, never errors.
    mirrorChunk(&shared, "more");
    try std.testing.expect(shared.mirror_failed);
}
