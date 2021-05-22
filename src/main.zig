/// All of the source code for this project lives in this file.
///
/// Its layout looks like this:
/// - entry point
/// - make        document generating
/// - models      data structures representing documents
/// - parsing     reading source documents into the models
/// - formatting  writing the models in the target format
/// - indexing    formatting lists of documents
/// - templates   rendering documents into templates
/// - utils       common functions that I didn't have another place for
///
/// If you want to add new features, you'll need to add the new block/span type
/// to the union, add the appropriate parser in the "parsing" section and hook it /// into the parsing flow. Then, in the formatting section, add handlers for your
/// new union fields for both targets
///
const std = @import("std");
const logger = std.log.scoped(.website);
const Date = @import("zig-date/src/main.zig").Date;

pub const log_level = if (std.builtin.mode == .Debug)
    std.logger.Level.debug
else
    std.log.Level.info;
/// Global variables aren't too hard to keep track of when you only have one file.
var include_private = false;
var env_map: std.BufMap = undefined;

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const held = std.debug.getStderrMutex().acquire();
    defer held.release();
    const stderr = std.io.getStdErr().writer();
    comptime const color: []const u8 = switch (message_level) {
        .emerg, .alert, .crit, .err => "\x1B[1;91m", // red
        .warn => "\x1B[1;93m", // yellow
        else => "",
    };
    comptime const reset = if (color.len > 0) "\x1B[0m" else "";
    nosuspend stderr.print(color ++ format ++ "\n" ++ reset, args) catch return;
}

pub fn main() u8 {
    mainWrapped() catch |err| {
        if (std.builtin.mode == .Debug) {
            std.debug.warn("{}{s}\n", .{ @errorReturnTrace(), @errorName(err) });
        } else return @intCast(u8, @errorToInt(err)) + 1;
    };
    return 0;
}

/// Entry point for the application
fn mainWrapped() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit()) logger.debug("Detected memory leak.", .{});

    env_map = try std.process.getEnvMap(&gpa.allocator);
    defer env_map.deinit();

    var args = try getArgs(&gpa.allocator);
    defer gpa.allocator.free(args);
    defer for (args) |arg| gpa.allocator.free(arg);
    const exe_name = args[0];
    comptime const usage =
        \\usage:
        \\  {s} <command> [<args>]
        \\
    ;
    comptime const help = usage ++
        \\
        \\commands:
        \\  make           The main generation tool
        \\  index          Outputs site indexes in various formats
        \\  docs           Print the sitegen documentation in sitegen format
        \\  html_template  Print the default html template
        \\  gmi_template  Print the default gmi template
    ;
    const stdout = std.io.getStdOut().writer();
    if (args.len <= 1) {
        try stdout.print(help, .{exe_name});
        return;
    }
    if (std.mem.eql(u8, args[1], "make")) {
        try make(exe_name, args[2..], &gpa.allocator);
    } else if (std.mem.eql(u8, args[1], "index")) {
        try buildIndex(exe_name, args[2..], &gpa.allocator);
    } else if (std.mem.endsWith(u8, args[1], "help")) {
        try stdout.print(help, .{exe_name});
    } else if (std.mem.eql(u8, args[1], "docs")) {
        try stdout.writeAll(@embedFile("docs.txt"));
    } else if (std.mem.eql(u8, args[1], "html_template")) {
        try stdout.writeAll(@embedFile("default_template.html"));
    } else if (std.mem.eql(u8, args[1], "gmi_template")) {
        try stdout.writeAll(@embedFile("default_template.gmi"));
    } else {
        logger.alert("Unknown command {s}", .{args[1]});
        try stdout.print(help, .{exe_name});
    }
}

// ---- MAKE ----

/// Generate the site for all targets
fn make(
    exe_name: []const u8,
    args: []const []const u8,
    allocator: *std.mem.Allocator,
) !void {
    var cwd = std.fs.cwd();

    var index: usize = 0;
    const usage =
        \\usage:
        \\  {0s} make [-p] [--private] [--html <template>] [--gmi <template>]   
        \\       [--] <out_dir> [<site_dir>]
        \\  {0s} make [--help]
        \\
    ;
    const help = usage ++
        \\
        \\arguments:
        \\  out_dir   the output folder for all generated content
        \\  site_dir  the input folder for the site itself, defaults to cwd
        \\options:
        \\  --help         show this text
        \\  -p, --private  include private content in the build
        \\  --html <template>  render html output with the template
        \\  --gmi <template>  render gmi output with the given template
    ;
    if (args.len == 0) {
        try std.io.getStdOut().writer().print(usage, .{exe_name});
        return;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var gmi_template_file: ?[]const u8 = null;
    var html_template_file: ?[]const u8 = null;
    while (index < args.len) : (index += 1) {
        if (getOpt(args[index], "private", 'p')) {
            include_private = true;
            try env_map.set("INCLUDE_PRIVATE", "--private");
        } else if (getOpt(args[index], "help", null)) {
            @setEvalBranchQuota(2000);
            try std.io.getStdOut().writer().print(help, .{exe_name});
            return;
        } else if (getOpt(args[index], "html", null)) {
            index += 1;
            html_template_file = args[index];
        } else if (getOpt(args[index], "gmi", null)) {
            index += 1;
            gmi_template_file = args[index];
        } else if (getOpt(args[index], "", null)) {
            index += 1;
            break;
        } else if (std.mem.startsWith(u8, args[index], "-")) {
            logger.alert("Unknown arg {s}", .{args[index]});
            return error.BadArgs;
        } else {
            break;
        }
    }

    const html_template = try getTemplate(&cwd, &arena.allocator, html_template_file, .html);
    const gmi_template = try getTemplate(&cwd, &arena.allocator, html_template_file, .gmi);

    if (index >= args.len) {
        logger.alert("Missing <out_dir> argument.", .{});
        try std.io.getStdOut().writer().print(usage, .{exe_name});
        return error.BadArgs;
    }
    try cwd.makePath(args[index]);
    var out_dir = try cwd.openDir(args[index], .{});
    defer out_dir.close();
    var html_dir = try out_dir.makeOpenPath("html", .{});
    defer html_dir.close();
    var gmi_dir = try out_dir.makeOpenPath("gmi", .{});
    defer gmi_dir.close();
    index += 1;
    var site_dir = try cwd.openDir(
        if (index < args.len) args[index] else ".",
        .{ .iterate = true },
    );
    // Ensures that child processes work as you might expect
    try site_dir.setAsCwd();
    defer site_dir.close();
    const render_options: RenderOptions = .{
        .html_template = &html_template,
        .gmi_template = &gmi_template,
        .allocator = allocator,
    };
    const targets: RenderTargets = .{
        .dirname = null,
        .src = &site_dir,
        .gmi = &gmi_dir,
        .html = &html_dir,
    };
    try renderDir(render_options, targets, null, 0);

    logger.info("Done!", .{});
}

pub const RenderOptions = struct {
    html_template: *const Template,
    gmi_template: *const Template,
    allocator: *std.mem.Allocator,
};
pub const RenderTargets = struct {
    dirname: ?[]const u8,
    src: *std.fs.Dir,
    gmi: *std.fs.Dir,
    html: *std.fs.Dir,
};

const RenderError = ParseError || ParseInfoError || std.fs.File.OpenError || std.fs.Dir.OpenError ||
    error{ LinkQuotaExceeded, ReadOnlyFileSystem, StreamTooLong };

/// Iterate over all files in a directory and render their output for each target
fn renderDir(options: RenderOptions, targets: RenderTargets, parent_title: ?[]const u8, depth: usize) RenderError!void {
    try targets.src.setAsCwd();
    var it = targets.src.iterate();

    const index_title = blk: {
        const index = targets.src.openFile("index.txt", .{}) catch |err| switch (err) {
            error.FileNotFound => std.debug.panic("No index file found in {s}.", .{targets.dirname}),
            else => |other_err| return other_err,
        };
        defer index.close();
        break :blk try index.reader().readUntilDelimiterAlloc(
            options.allocator,
            '\n',
            1024 * 1024,
        );
    };
    defer options.allocator.free(index_title);

    while (try it.next()) |item| switch (item.kind) {
        .File => {
            const whitespace = Whitespace{ .size = 2 * depth };
            logger.info("{}{s}", .{ whitespace, item.name });
            try renderFile(
                options,
                targets,
                if (std.mem.eql(u8, item.name, "index.txt")) parent_title else index_title,
                item.name,
            );
        },
        .Directory => {
            var src_subdir = try targets.src.openDir(item.name, .{ .iterate = true });
            try src_subdir.setAsCwd();
            defer targets.src.setAsCwd() catch unreachable;
            defer src_subdir.close();
            var html_subdir = try targets.html.makeOpenPath(item.name, .{});
            defer html_subdir.close();
            var gmi_subdir = try targets.gmi.makeOpenPath(item.name, .{});
            defer gmi_subdir.close();
            const whitespace = Whitespace{ .size = 2 * depth };
            logger.info("{}{s}:", .{ whitespace, item.name });
            const subdir_name = if (targets.dirname) |dirname|
                try std.fs.path.join(options.allocator, &[_][]const u8{
                    dirname,
                    item.name,
                })
            else
                item.name;
            defer if (targets.dirname != null) options.allocator.free(subdir_name);
            const subtargets = RenderTargets{
                .dirname = item.name,
                .html = &html_subdir,
                .gmi = &gmi_subdir,
                .src = &src_subdir,
            };
            try renderDir(options, subtargets, index_title, depth + 1);
        },
        else => {},
    };
}

fn renderFile(
    options: RenderOptions,
    targets: RenderTargets,
    parent_name: ?[]const u8,
    filename: []const u8,
) RenderError!void {
    if (!std.mem.endsWith(u8, filename, ".txt")) return;
    var arena = std.heap.ArenaAllocator.init(options.allocator);
    defer arena.deinit();
    const filename_no_ext = filename[0 .. filename.len - 4];
    const file_info = FileInfo{
        .name = filename_no_ext,
        .dir = targets.dirname,
        .parent_title = parent_name,
    };
    const src_file = try targets.src.openFile(filename, .{});
    defer src_file.close();
    const lines = try readLines(src_file.reader(), &arena.allocator);
    const doc = try parseDocument(lines, &arena.allocator, file_info);
    if (doc.info.private and !include_private) return;
    inline for (@typeInfo(Ext).Enum.fields) |field| {
        comptime const ext = @field(Ext, field.name);
        const dir = @field(targets, field.name);
        const template = @field(options, field.name ++ "_template");
        const out_filename = try std.mem.concat(
            &arena.allocator,
            u8,
            &[_][]const u8{ filename_no_ext, "." ++ field.name },
        );
        defer arena.allocator.free(out_filename);
        const out_file = try dir.createFile(
            out_filename,
            .{ .truncate = true },
        );
        defer out_file.close();
        const writer = out_file.writer();
        try formatTemplate(template.header, doc.info, file_info, writer);
        for (doc.blocks) |block| switch (ext) {
            .html => try formatBlockHtml(block, writer),
            .gmi => try formatBlockGmi(block, writer),
        };
        try formatTemplate(template.footer, doc.info, file_info, writer);
    }
}

// ---- MODELS ----

/// The possible rendering targets
const Ext = enum { html, gmi };

/// A parsed document
const Document = struct { blocks: []const Block, info: Info };

/// The metadata at the top of the document
const Info = struct {
    title: []const u8,
    created: Date,
    changes: []const Change,
    private: bool = false,
    unlisted: bool = false,
};

const FileInfo = struct { name: []const u8, dir: ?[]const u8, parent_title: ?[]const u8 };
const ParseContext = struct {
    info: Info,
    file: FileInfo,
    allocator: *std.mem.Allocator,
};

const Change = struct { date: Date, what_changed: ?[]const u8 = null };

/// A line-level block of text
const Block = union(enum) {
    paragraph: []const Span,
    raw: Raw,
    heading: []const u8,
    subheading: []const u8,
    quote: []const []const Span,
    list: []const []const Span,
    link: Link,
    preformatted: []const []const u8,
    empty,
    image: Image,
};

const Image = struct { source: []const u8, alt: []const u8, title: []const u8 };

/// Text that should be copied as-is into the output IF the current rendering
/// target matches the extension
const Raw = struct { ext: Ext, lines: []const []const u8 };

/// A line-level link
const Link = struct {
    url: []const u8,
    text: ?[]const u8 = null,
    auto_ext: bool = false,
    hash: ?[]const u8 = null,
};

/// Inline formatting. Ignored entirely by gemini.
const Span = union(enum) {
    text: []const u8,
    strong: []const Span,
    emphasis: []const Span,
    anchor: Anchor,
    br,
};

/// An inline link.
const Anchor = struct { url: []const u8, text: []const Span };

// ---- PARSING ----

/// I have a specific parsing model I like to use that works pretty well for me.
/// First, all of the document is split into a span of text lines. If a parsing
/// function could consume multiple lines, it takes all of the lines (including
/// those already consumed) along with a start index, then returns the resulting
/// structure along with the new index if it found a match. If no match was found
/// it returns null.
/// What I like about this is that we always have the context of the current line
/// number close on hand so that if we need to put out helpful log messages, we
/// can, and it's easy to write "speculative parsers" that go along doing their
/// to parse a format, but can "rewind" harmlessly if something goes wrong.
/// In general, this also means that errors don't really happen, because if you
/// mistype something it'll usually just fall back to raw text.
fn parseDocument(
    lines: []const []const u8,
    allocator: *std.mem.Allocator,
    file: FileInfo,
) !Document {
    const info_res = try parseInfo(lines, allocator);
    const context = ParseContext{ .file = file, .allocator = allocator, .info = info_res.data };
    const blocks = try parseBlocks(lines, info_res.new_pos + 1, context);

    const result: Document = .{
        .blocks = blocks,
        .info = info_res.data,
    };
    return result;
}

/// wow so many things can go wrong with computers
const ParseError = error{
    ProcessEndedUnexpectedly,
    SpanNotClosed,
} || std.mem.Allocator.Error ||
    std.process.GetEnvVarOwnedError || std.fs.File.ReadError ||
    std.fs.File.WriteError || std.ChildProcess.SpawnError;

const ParseInfoError = std.mem.Allocator.Error ||
    error{ NoInfo, NoCreatedDate, UnexpectedInfo, FailedToMatchLiteral, EndOfStream, InvalidDay };

fn ParseResult(comptime Type: type) type {
    return struct {
        data: Type,
        new_pos: usize,
    };
}

/// Shorthand for building ParseResults
fn ok(data: anytype, new_pos: usize) ParseResult(@TypeOf(data)) {
    return .{
        .data = data,
        .new_pos = new_pos,
    };
}

fn parseInfo(
    lines: []const []const u8,
    allocator: *std.mem.Allocator,
) ParseInfoError!ParseResult(Info) {
    if (lines.len == 0) return error.NoInfo;
    const title = lines[0];
    var created: ?Date = null;
    var changes = std.ArrayList(Change).init(allocator);
    errdefer changes.deinit();
    var line: usize = 1;
    var private = false;
    var unlisted = false;
    while (line < lines.len and lines[line].len > 0) : (line += 1) {
        if (parseLiteral(lines[line], 0, "Written ")) |index| {
            created = try Date.parse(lines[line][index..]);
        } else if (parseLiteral(lines[line], 0, "Updated ")) |index| {
            var date = try Date.parse(lines[line][index..]);
            const what_changed_start = index + "0000-00-00".len + 1;
            if (lines[line].len > what_changed_start) {
                try changes.append(.{
                    .date = date,
                    .what_changed = lines[line][what_changed_start..],
                });
            } else {
                try changes.append(.{ .date = date });
            }
        } else if (std.mem.eql(u8, lines[line], "Private")) {
            private = true;
        } else if (std.mem.eql(u8, lines[line], "Unlisted")) {
            unlisted = true;
        } else {
            logger.alert("Could not parse info on line {}:", .{line});
            logger.info("{d}: {s}", .{ line, lines[line] });
            return error.UnexpectedInfo;
        }
    }
    return ok(Info{
        .title = title,
        .created = created orelse return error.NoCreatedDate,
        .changes = changes.toOwnedSlice(),
        .private = private,
        .unlisted = unlisted,
    }, line);
}

/// The basic idea for blocks is: if it's not anything else, it's a paragraph.
/// So, we try to parse various block patterns, and if nothing matches, we
/// add a line of paragraph text which will be "flushed out" as soon as something
/// DOES match (or the end of the file).
fn parseBlocks(
    lines: []const []const u8,
    start: usize,
    context: ParseContext,
) ParseError![]const Block {
    var index = start;
    var blocks = std.ArrayList(Block).init(context.allocator);
    var spans = std.ArrayList(Span).init(context.allocator);
    while (index < lines.len) {
        if (try parseCommand(lines, index, context)) |res| {
            if (spans.items.len > 0) {
                try blocks.append(.{ .paragraph = spans.toOwnedSlice() });
            }
            try blocks.appendSlice(res.data);
            index = res.new_pos;
        } else if (try parseBlock(lines, index, context.allocator)) |res| {
            if (spans.items.len > 0) {
                try blocks.append(.{ .paragraph = spans.toOwnedSlice() });
            }
            try blocks.append(res.data);
            index = res.new_pos;
        } else if (try parseSpans(lines[index], 0, null, null, context.allocator)) |res| {
            index += 1;
            if (spans.items.len > 0) {
                try spans.append(.{ .br = {} });
            }
            try spans.appendSlice(res.data);
        } else {
            index += 1;
        }
    }
    if (spans.items.len > 0) {
        try blocks.append(.{ .paragraph = spans.toOwnedSlice() });
    }
    return blocks.toOwnedSlice();
}

/// This is the fun stuff. Everything written inside of a command block is piped
/// into the shell, and the output is then parsed as blocks like any other
/// content. Not very much code and A LOT of power.
fn parseCommand(
    lines: []const []const u8,
    start: usize,
    context: ParseContext,
) !?ParseResult([]const Block) {
    if (try parsePrefixedLines(
        lines,
        start,
        ":",
        context.allocator,
    )) |res| {
        defer context.allocator.free(res.data);
        const shell = try std.process.getEnvVarOwned(context.allocator, "SHELL");

        var process = try std.ChildProcess.init(
            &[_][]const u8{shell},
            context.allocator,
        );
        defer process.deinit();
        try env_map.set("FILE", context.file.name);
        process.env_map = &env_map;
        process.stdin_behavior = .Pipe;
        process.stdout_behavior = .Pipe;

        try process.spawn();
        errdefer _ = process.kill() catch |err| {
            logger.warn("Had trouble cleaning up process: {}", .{err});
        };
        const writer = process.stdin.?.writer();
        for (res.data) |line| {
            try writer.print("{s}\n", .{line});
        }
        process.stdin.?.close();
        process.stdin = null;

        const result_lines = try readLines(
            process.stdout.?.reader(),
            context.allocator,
        );
        switch (try process.wait()) {
            .Exited => |status| {
                if (status != 0) {
                    logger.alert("Process ended unexpectedly on line {d}", .{
                        res.new_pos,
                    });
                    return error.ProcessEndedUnexpectedly;
                }
                return ok(
                    try parseBlocks(result_lines, 0, context),
                    res.new_pos,
                );
            },
            else => return error.ProcessEndedUnexpectedly,
        }
    }
    return null;
}

fn parseBlock(
    lines: []const []const u8,
    line: usize,
    allocator: *std.mem.Allocator,
) !?ParseResult(Block) {
    if (lines[line].len == 0) {
        return ok(Block{ .empty = {} }, line + 1);
    } else if (try parseRaw(lines, line, allocator)) |res| {
        return ok(Block{ .raw = res.data }, res.new_pos);
    } else if (try parsePrefixedLines(lines, line, " ", allocator)) |res| {
        return ok(Block{ .preformatted = res.data }, res.new_pos);
    } else if (try parseWrapper(lines, line, "> ", allocator)) |res| {
        return ok(Block{ .quote = res.data }, res.new_pos);
    } else if (parseHeading(lines[line])) |heading| {
        return ok(Block{ .heading = heading }, line + 1);
    } else if (parseSubheading(lines[line])) |subheading| {
        return ok(Block{ .subheading = subheading }, line + 1);
    } else if (try parseLink(lines[line])) |link| {
        return ok(Block{ .link = link }, line + 1);
    } else if (try parseList(lines, line, allocator, "- ")) |res| {
        return ok(Block{ .list = res.data }, res.new_pos);
    } else if (try parseImage(lines, line)) |res| {
        return ok(Block{ .image = res.data }, res.new_pos);
    } else return null;
}

fn parseRaw(lines: []const []const u8, start: usize, allocator: *std.mem.Allocator) !?ParseResult(Raw) {
    inline for (@typeInfo(Ext).Enum.fields) |fld| {
        if (try parsePrefixedLines(lines, start, "." ++ fld.name, allocator)) |res| {
            return ok(
                Raw{ .ext = @field(Ext, fld.name), .lines = res.data },
                res.new_pos,
            );
        }
    }
    return null;
}

fn parsePrefixedLines(
    lines: []const []const u8,
    start: usize,
    comptime prefix: []const u8,
    allocator: *std.mem.Allocator,
) !?ParseResult([]const []const u8) {
    if (!std.mem.startsWith(u8, lines[start], prefix ++ " ")) return null;
    var line = start;
    var result = std.ArrayList([]const u8).init(allocator);
    while (line < lines.len) : (line += 1) {
        if (parseLiteral(lines[line], 0, prefix ++ " ")) |index| {
            try result.append(lines[line][index..]);
        } else break;
    }
    return ok(@as([]const []const u8, result.toOwnedSlice()), line);
}

fn parseHeading(line: []const u8) ?[]const u8 {
    if (parseLiteral(line, 0, "# ")) |index| return line[index..];
    return null;
}

fn parseSubheading(line: []const u8) ?[]const u8 {
    if (parseLiteral(line, 0, "## ")) |index| return line[index..];
    return null;
}

fn parseList(
    lines: []const []const u8,
    start: usize,
    allocator: *std.mem.Allocator,
    comptime symbol: []const u8,
) ParseError!?ParseResult([]const []const Span) {
    var ll = start;
    if (!std.mem.startsWith(u8, lines[ll], symbol)) return null;
    var items = std.ArrayList([]const Span).init(allocator);
    while (ll < lines.len and
        std.mem.startsWith(u8, lines[ll], symbol)) : (ll += 1)
    {
        if (try parseSpans(
            lines[ll],
            symbol.len,
            null,
            null,
            allocator,
        )) |result| {
            try items.append(result.data);
        } else {
            try items.append(&[0]Span{});
        }
    }
    errdefer items.deinit();
    return ok(@as([]const []const Span, items.toOwnedSlice()), ll);
}

fn parseLink(line: []const u8) !?Link {
    const url_start = parseLiteral(line, 0, "=> ") orelse return null;
    const url_end = std.mem.indexOfPos(
        u8,
        line,
        url_start,
        " ",
    ) orelse return null;
    const hash_start = std.mem.indexOfPos(u8, line[0..url_end], url_start, "#");
    const hash = if (hash_start) |start| line[start + 1 .. url_end] else null;
    const text = line[url_end + 1 ..];
    const url = line[url_start .. hash_start orelse url_end];

    if (std.mem.endsWith(u8, url, ".*")) {
        return Link{
            .url = url[0 .. url.len - 2],
            .text = text,
            .auto_ext = true,
            .hash = hash,
        };
    } else {
        return Link{
            .url = url,
            .text = text,
            .hash = hash,
        };
    }
}

fn parseImage(lines: []const []const u8, start: usize) !?ParseResult(Image) {
    if (start + 1 >= lines.len) return null;
    const url_start = parseLiteral(lines[start], 0, "!> ") orelse return null;
    const alt_start = parseLiteral(lines[start + 1], 0, "  ") orelse
        return null;
    const url_end = std.mem.indexOfPos(u8, lines[start], url_start, " ") orelse
        return null;
    return ok(Image{
        .source = lines[start][url_start..url_end],
        .title = lines[start][url_end + 1 ..],
        .alt = lines[start + 1][alt_start..],
    }, start + 2);
}

fn parseWrapper(
    lines: []const []const u8,
    start: usize,
    comptime prefix: []const u8,
    allocator: *std.mem.Allocator,
) !?ParseResult([]const []const Span) {
    if (!std.mem.startsWith(u8, lines[start], prefix)) return null;
    var line = start;
    var paragraphs = std.ArrayList([]const Span).init(allocator);
    var spans = std.ArrayList(Span).init(allocator);
    while (line < lines.len and std.mem.startsWith(u8, lines[line], prefix)) : (line += 1) {
        if (lines[line].len == prefix.len) {
            if (spans.items.len > 0) {
                try paragraphs.append(spans.toOwnedSlice());
            }
        } else if (try parseSpans(
            lines[line],
            prefix.len,
            null,
            null,
            allocator,
        )) |res| {
            if (spans.items.len > 0) {
                try spans.append(.br);
            }
            try spans.appendSlice(res.data);
        }
    }
    if (spans.items.len > 0) {
        try paragraphs.append(spans.toOwnedSlice());
    }
    return ok(@as([]const []const Span, paragraphs.toOwnedSlice()), line);
}

/// Parsing spans applies the exact same principles as parsing blocks, except
/// using column indexes in single lines instead of row index in lists of lines.
/// With the exception of the outermost content, spans are usually wrapped in
/// something (like *bold text*), and so you can provide the open and close
/// arguments to nest span parsing so that something silly like *_*IMPORTANT*_*
/// actually applies nested <strong><em><strong> tags.
fn parseSpans(
    line: []const u8,
    start: usize,
    comptime open: ?[]const u8,
    comptime close: ?[]const u8,
    allocator: *std.mem.Allocator,
) ParseError!?ParseResult([]const Span) {
    var col = start;
    if (open) |match| {
        col = parseLiteral(line, col, match) orelse return null;
    }
    var spans = std.ArrayList(Span).init(allocator);
    var text = std.ArrayList(u8).init(allocator);
    while (col < line.len) {
        if (close) |match| if (parseLiteral(line, col, match) != null) break;
        if (try parseSpan(line, col, allocator)) |res| {
            if (text.items.len > 0) {
                try spans.append(.{ .text = text.toOwnedSlice() });
            }
            try spans.append(res.data);
            col = res.new_pos;
        } else {
            try text.append(line[col]);
            col += 1;
        }
    } else if (close) |match| {
        // TODO there might be a minor memory leak here
        text.deinit();
        spans.deinit();
        return null;
    }
    if (text.items.len > 0) {
        try spans.append(.{ .text = text.toOwnedSlice() });
    }
    const consumed = if (close) |match| col + match.len else col;
    if (spans.items.len == 0) return null;
    return ok(@as([]const Span, spans.toOwnedSlice()), consumed);
}

fn parseSpan(
    line: []const u8,
    start: usize,
    allocator: *std.mem.Allocator,
) ParseError!?ParseResult(Span) {
    if (try parseSpans(line, start, "_", "_", allocator)) |result| {
        return ok(Span{ .emphasis = result.data }, result.new_pos);
    } else if (try parseSpans(line, start, "*", "*", allocator)) |result| {
        return ok(Span{ .strong = result.data }, result.new_pos);
    } else if (try parseAnchor(line, start, allocator)) |result| {
        return ok(Span{ .anchor = result.data }, result.new_pos);
    } else return null;
}

fn parseAnchor(
    line: []const u8,
    start: usize,
    allocator: *std.mem.Allocator,
) ParseError!?ParseResult(Anchor) {
    if (try parseSpans(line, start, "[", "](", allocator)) |res| {
        const end_index = std.mem.indexOfPos(
            u8,
            line,
            res.new_pos,
            ")",
        ) orelse return null;
        return ok(Anchor{
            .text = res.data,
            .url = line[res.new_pos..end_index],
        }, end_index + 1);
    }
    return null;
}

// ---- COMMON FORMATTING ----

/// Pretty typical, you probably wouldn't even need to change this if you were
/// altering the template.
const html_preamble =
    \\<!DOCTYPE html>
    \\<html>
    \\<head>
    \\<meta charset="UTF-8"/>
    \\<meta name="viewport" content="width=device-width, initial-scale=1.0">
    \\<link rel="stylesheet" type="text/css" href="/style.css" />
    \\<link rel="icon" type="image/png" href="assets/favicon.png" />
    \\
;

// ---- HTML FORMATTING ----

fn formatBlockHtml(
    block: Block,
    writer: anytype,
) @TypeOf(writer).Error!void {
    switch (block) {
        .paragraph => |paragraph| {
            try writer.writeAll("<p>");
            for (paragraph) |span| try formatSpanHtml(span, writer);
            try writer.writeAll("</p>\n");
        },
        .heading => |heading| {
            try writer.writeAll("<h2 id=\"");
            try formatId(heading, writer);
            const text = HtmlText.init(heading);
            try writer.print("\">{s}</h2>\n", .{text});
        },
        .subheading => |subheading| {
            try writer.writeAll("<h3 id=\"");
            try formatId(subheading, writer);
            const text = HtmlText.init(subheading);
            try writer.print("\">{s}</h2>\n", .{text});
        },
        .raw => |raw| switch (raw.ext) {
            .html => for (raw.lines) |line| {
                try writer.print("{s}\n", .{line});
            },
            else => {},
        },
        .link => |link| {
            logger.debug("Link {s} {s} {s}", .{ link.url, link.hash, link.text });
            const text = HtmlText.init(link.text orelse link.url);
            const url = HtmlText.init(link.url);
            try writer.print("<a href=\"{s}", .{url});
            if (link.auto_ext) {
                try writer.writeAll(".html");
            }
            if (link.hash) |hash| {
                try writer.print("#{s}", .{hash});
            }
            try writer.print("\">{s}</a>\n", .{text});
        },
        .list => |list| {
            try writer.writeAll("<ul>\n");
            for (list) |item| {
                try writer.writeAll("  <li>");
                for (item) |span| try formatSpanHtml(span, writer);
                try writer.writeAll("</li>\n");
            }
            try writer.writeAll("</ul>");
        },
        .quote => |paragraphs| {
            try writer.writeAll("<blockquote>\n");
            for (paragraphs) |p| {
                try formatBlockHtml(Block{ .paragraph = p }, writer);
            }
            try writer.writeAll("</blockquote>\n");
        },
        .preformatted => |lines| {
            try writer.writeAll("<pre>\n");
            for (lines) |line| {
                const text = HtmlText.init(line);
                try writer.print("{s}\n", .{text});
            }
            try writer.writeAll("</pre>\n");
        },
        .image => |image| {
            try writer.print("<img src=\"{s}\" alt=\"{s}\">\n", .{
                image.source,
                HtmlText.init(image.alt),
            });
        },
        .empty => {},
    }
}

fn formatSpanHtml(span: Span, writer: anytype) @TypeOf(writer).Error!void {
    switch (span) {
        .text => |text| {
            const formatted = HtmlText.init(text);
            try writer.print("{}", .{formatted});
        },
        .emphasis => |spans| {
            try writer.writeAll("<em>");
            for (spans) |sp| try formatSpanHtml(sp, writer);
            try writer.writeAll("</em>");
        },
        .strong => |spans| {
            try writer.writeAll("<strong>");
            for (spans) |sp| try formatSpanHtml(sp, writer);
            try writer.writeAll("</strong>");
        },
        .anchor => |anchor| {
            try writer.print(
                \\<a href="{s}">
            , .{anchor.url});
            for (anchor.text) |sp| try formatSpanHtml(sp, writer);
            try writer.writeAll("</a>");
        },
        .br => try writer.writeAll("<br>\n"),
    }
}

pub fn formatId(string: []const u8, writer: anytype) !void {
    for (string) |char| switch (char) {
        ' ' => try writer.writeByte('-'),
        '?' => {},
        else => try writer.writeByte(char),
    };
}

pub const HtmlText = struct {
    text: []const u8,
    fn init(text: []const u8) @This() {
        return .{ .text = text };
    }
    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        for (self.text) |char| switch (char) {
            '>' => try writer.writeAll("&gt;"),
            '<' => try writer.writeAll("&lt;"),
            '\"' => try writer.writeAll("&quot;"),
            '&' => try writer.writeAll("&amp;"),
            else => try writer.writeByte(char),
        };
    }
};

// ---- GEMINI FORMATTING ----

fn formatParagraphGmi(
    spans: []const Span,
    comptime br: []const u8,
    writer: anytype,
) !void {
    for (spans) |span| {
        try formatSpanGmi(span, br, writer);
    }
    try writer.writeAll("\n");
}

fn formatBlockGmi(
    block: Block,
    writer: anytype,
) @TypeOf(writer).Error!void {
    switch (block) {
        .paragraph => |paragraph| {
            try formatParagraphGmi(paragraph, "\n", writer);
        },
        .heading => |heading| {
            try writer.print("## {s}\n", .{heading});
        },
        .subheading => |subheading| {
            try writer.print("### {s}\n", .{subheading});
        },
        .raw => |raw| switch (raw.ext) {
            .gmi => for (raw.lines) |line| {
                try writer.print("{s}\n", .{line});
            },
            else => {},
        },
        .link => |link| {
            try writer.print("=> {s}", .{link.url});
            if (link.auto_ext) {
                try writer.writeAll(".gmi");
            }
            if (link.text) |text| {
                try writer.print(" {s}", .{text});
            }
            try writer.writeByte('\n');
        },
        .list => |list| {
            for (list) |item| {
                try writer.writeAll("* ");
                for (item) |span| try formatSpanGmi(span, " ", writer);
                try writer.writeAll("\n");
            }
        },
        .quote => |paragraphs| {
            for (paragraphs) |p, i| {
                if (i != 0) try writer.writeAll("> \n");
                try writer.writeAll("> ");
                try formatParagraphGmi(p, "\n> ", writer);
            }
        },
        .preformatted => |lines| {
            try writer.writeAll("```\n");
            for (lines) |line| {
                try writer.print("{s}\n", .{line});
            }
            try writer.writeAll("```\n");
        },
        .image => |image| {
            try writer.print("=> {s} {s}\n", .{ image.source, image.title });
        },
        .empty => try writer.writeAll("\n"),
    }
}

fn formatSpanGmi(
    span: Span,
    comptime br: []const u8,
    writer: anytype,
) @TypeOf(writer).Error!void {
    switch (span) {
        .text => |text| try writer.writeAll(text),
        .emphasis,
        .strong,
        => |spans| for (spans) |sp| try formatSpanGmi(sp, "", writer),
        .anchor => |anchor| for (anchor.text) |sp|
            try formatSpanGmi(sp, "", writer),
        .br => try writer.writeAll(br),
    }
}

// ---- INDEXING ----

/// A document that has only had the metadata parsed, for indexing
const IndexEntry = struct {
    filename: []const u8,
    date: Date,
    event: union(enum) { written, updated: ?[]const u8 },
    info: Info,
};

/// The 'sitegen index' command. Operates on collections of documents. Useful for
/// building directories or feeds.
fn buildIndex(
    exe_name: []const u8,
    args: []const []const u8,
    allocator: *std.mem.Allocator,
) !void {
    var arg_i: usize = 0;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const usage =
        \\usage:
        \\  {0s} index [--help]
        \\  {0s} index [--private] [--limit <num>] [--updates | --additions] [--] 
        \\    <file> [<file>...]
    ;
    const help = usage ++
        \\
        \\options:
        \\  -p, --private            include private content in the list
        \\  -l <num>, --limit <num>  limit the number of entries to the top num
        \\  -u, --updates            only include updates (and not additions)
        \\  -a, --additions          only include additions (and not updates)
    ;
    const stdout = std.io.getStdOut().writer();
    if (args.len == 0) {
        try stdout.print(usage, .{exe_name});
        return;
    }
    var limit: ?usize = null;
    var include_updates = true;
    var include_additions = true;
    while (arg_i < args.len) : (arg_i += 1) {
        const arg = args[arg_i];
        if (getOpt(arg, "private", 'p')) {
            include_private = true;
        } else if (getOpt(arg, "help", null)) {
            @setEvalBranchQuota(2000);
            try stdout.print(help, .{exe_name});
            return;
        } else if (getOpt(arg, "limit", 'l')) {
            arg_i += 1;
            limit = std.fmt.parseInt(usize, args[arg_i], 10) catch {
                logger.alert("Limit value must be positive integer, got: {s}", .{
                    args[arg_i],
                });
                return error.BadArgs;
            };
        } else if (getOpt(arg, "updates", 'u')) {
            include_additions = false;
        } else if (getOpt(arg, "additions", 'a')) {
            include_updates = false;
        } else if (getOpt(arg, "-", null)) {
            arg_i += 1;
            break;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            logger.alert("Unknown argument {s}", .{arg});
            return error.BadArgs;
        } else break;
    }
    if (arg_i >= args.len) {
        logger.alert("Missing argument <file>.", .{});
        try stdout.print(usage, .{exe_name});
        return;
    }
    var files = std.ArrayList([]const u8).init(&arena.allocator);
    while (arg_i < args.len) : (arg_i += 1) {
        try files.append(args[arg_i]);
    }
    const cwd = std.fs.cwd();
    var pages = std.ArrayList(IndexEntry).init(&arena.allocator);
    for (files.items) |filename| {
        if (!std.mem.endsWith(u8, filename, ".txt")) {
            logger.warn("Invalid index file {s}, files must be .txt. Skipping.", .{
                filename,
            });
            continue;
        }
        var file = try cwd.openFile(filename, .{});
        defer file.close();

        const lines = blk: {
            var lines = std.ArrayList([]const u8).init(
                &arena.allocator,
            );
            var line = std.ArrayList(u8).init(&arena.allocator);
            while (try readLine(file.reader(), &line)) {
                if (line.items.len == 0) break;
                try lines.append(line.toOwnedSlice());
            }
            break :blk lines.toOwnedSlice();
        };
        // logger.debug("Adding {s} to index", .{filename});
        var info = (try parseInfo(lines, allocator)).data;
        defer allocator.free(info.changes);
        if (info.unlisted) continue;
        if (info.private and !include_private) continue;

        const filename_no_ext = filename[0 .. filename.len - 4];
        if (include_updates) {
            for (info.changes) |change| {
                try pages.append(.{
                    .filename = filename_no_ext,
                    .info = info,
                    .event = .{ .updated = change.what_changed },
                    .date = change.date,
                });
            }
        }
        if (include_additions) {
            try pages.append(.{
                .filename = filename_no_ext,
                .info = info,
                .event = .written,
                .date = info.created,
            });
        }
    }
    const sortFn = struct {
        fn laterThan(context: void, lhs: IndexEntry, rhs: IndexEntry) bool {
            const result = lhs.date.isAfter(rhs.date);
            return result;
        }
    }.laterThan;
    std.sort.sort(IndexEntry, pages.items, {}, sortFn);
    if (limit) |limit_val| {
        if (limit_val < pages.items.len) {
            pages.shrinkAndFree(limit_val);
        }
    }
    try formatIndexMarkup(stdout, pages.items);
}

fn formatIndexMarkup(writer: anytype, pages: []const IndexEntry) !void {
    for (pages) |page| {
        if (page.info.private) {
            try writer.writeAll("; ");
        }
        try writer.print("=> {s}.* {} – {s}", .{
            page.filename,
            page.date,
            page.info.title,
        });
        switch (page.event) {
            .written => {},
            .updated => |what_changed| {
                const change = what_changed orelse "updated";
                try writer.print(" – {s}", .{change});
            },
        }
        try writer.writeByte('\n');
    }
}

// ---- TEMPLATES ----

const Template = struct {
    header: []const TemplateNode,
    footer: []const TemplateNode,
};

const TemplateNode = union(enum) {
    text: []const u8,
    variable: TemplateVariable,
    conditional: TemplateConditional,
};

const TemplateVariableName = enum {
    title,
    file,
    dir,
    written,
    updated,
    back_text,
    back,
    parent_name,
    parent,
};

const TemplateVariable = struct {
    name: TemplateVariableName,
    format: ?[]const u8 = null,
};

const TemplateConditional = struct {
    name: TemplateVariableName,
    output: []const TemplateNode,
};

fn getTemplate(cwd: *std.fs.Dir, allocator: *std.mem.Allocator, template_file: ?[]const u8, comptime ext: Ext) !Template {
    return try parseTemplate(
        if (template_file) |file|
            try cwd.readFileAlloc(
                allocator,
                file,
                1024 * 1024 * 1024,
            )
        else
            @embedFile("default_template." ++ @tagName(ext)),
        allocator,
    );
}

fn parseTemplate(text: []const u8, allocator: *std.mem.Allocator) !Template {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var index: usize = 0;
    var text_start = index;
    var header = std.ArrayList(TemplateNode).init(&arena.allocator);
    var footer = std.ArrayList(TemplateNode).init(&arena.allocator);
    var parsed_header = false;
    var result = &header;
    while (index < text.len) {
        if (parseLiteral(text, index, "{{content}}")) |new_pos| {
            if (index > text_start) {
                try header.append(.{ .text = text[text_start..index] });
            }
            index = new_pos;
            text_start = index;
            break;
        } else if (try parseTemplateVariable(
            text,
            index,
            &arena.allocator,
        )) |res| {
            if (index > text_start) {
                try header.append(.{ .text = text[text_start..index] });
            }
            index = res.new_pos;
            text_start = index;
            try header.append(res.data);
        } else {
            index += 1;
        }
    }
    if (index > text_start) {
        try header.append(.{ .text = text[text_start..index] });
    }
    while (index < text.len) {
        if (try parseTemplateVariable(
            text,
            index,
            &arena.allocator,
        )) |res| {
            if (index > text_start) {
                try footer.append(.{ .text = text[text_start..index] });
            }
            index = res.new_pos;
            text_start = index;
            try footer.append(res.data);
        } else {
            index += 1;
        }
    }
    if (index > text_start) {
        try footer.append(.{ .text = text[text_start..index] });
    }
    return Template{
        .header = header.toOwnedSlice(),
        .footer = footer.toOwnedSlice(),
    };
}

fn parseTemplateVariableName(
    text: []const u8,
    start: usize,
) ?ParseResult(TemplateVariableName) {
    if (start >= text.len) return null;
    inline for (@typeInfo(TemplateVariableName).Enum.fields) |fld| {
        if (parseLiteral(text, start, fld.name)) |index| {
            return ok(@field(TemplateVariableName, fld.name), index);
        }
    }
    return null;
}

fn parseTemplateVariableFormat(
    text: []const u8,
    start: usize,
) ?ParseResult([]const u8) {
    if (start >= text.len) return null;
    const text_start = parseLiteral(text, start, "|") orelse return null;
    const text_end = std.mem.indexOfPos(u8, text, text_start, "}}") orelse
        return null;
    return ok(text[text_start..text_end], text_end + 2);
}

fn parseTemplateConditional(
    text: []const u8,
    start: usize,
    allocator: *std.mem.Allocator,
) std.mem.Allocator.Error!?ParseResult([]const TemplateNode) {
    var index = parseLiteral(text, start, "?") orelse return null;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var text_start = index;
    var result = std.ArrayList(TemplateNode).init(&arena.allocator);
    while (index < text.len) {
        if (parseLiteral(text, index, "}}")) |new_index| {
            if (index > text_start) {
                try result.append(.{ .text = text[text_start..index] });
            }
            return ok(
                @as([]const TemplateNode, result.toOwnedSlice()),
                new_index,
            );
        } else if (try parseTemplateVariable(
            text,
            index,
            &arena.allocator,
        )) |res| {
            if (index > text_start) {
                try result.append(.{ .text = text[text_start..index] });
            }
            index = res.new_pos;
            text_start = index;
            try result.append(res.data);
        } else {
            index += 1;
        }
    }
    arena.deinit();
    return null;
}

fn parseTemplateVariable(
    text: []const u8,
    start: usize,
    allocator: *std.mem.Allocator,
) std.mem.Allocator.Error!?ParseResult(TemplateNode) {
    var index = start;
    index = parseLiteral(text, index, "{{") orelse return null;
    const name_res = parseTemplateVariableName(text, index) orelse return null;

    index = name_res.new_pos;
    if (parseTemplateVariableFormat(text, index)) |format_res| {
        return ok(TemplateNode{
            .variable = .{
                .name = name_res.data,
                .format = format_res.data,
            },
        }, format_res.new_pos);
    } else if (try parseTemplateConditional(
        text,
        index,
        allocator,
    )) |cond_res| {
        return ok(TemplateNode{
            .conditional = .{
                .name = name_res.data,
                .output = cond_res.data,
            },
        }, cond_res.new_pos);
    }
    const end_index = parseLiteral(text, index, "}}") orelse return null;
    return ok(TemplateNode{ .variable = .{ .name = name_res.data } }, end_index);
}

fn formatTemplate(
    template: []const TemplateNode,
    info: Info,
    file: FileInfo,
    writer: anytype,
) @TypeOf(writer).Error!void {
    for (template) |node| switch (node) {
        .text => |text| try writer.writeAll(text),
        .variable => |variable| switch (variable.name) {
            .written => {
                try info.created.formatRuntime(
                    variable.format orelse "",
                    writer,
                );
            },
            .updated => {
                if (info.changes.len > 0) {
                    try info.changes[info.changes.len - 1].date.formatRuntime(
                        variable.format orelse "",
                        writer,
                    );
                }
            },
            .title => try writer.writeAll(info.title),
            .file => try writer.writeAll(file.name),
            .dir => if (file.dir) |dir| try writer.writeAll(dir),
            .back, .parent => {
                try writer.writeByte('.');
                if (file.dir) |dir| {
                    if (std.mem.eql(u8, file.name, "index")) {
                        try writer.writeByte('.');
                    }
                }
            },
            .back_text, .parent_name => {
                if (file.parent_title) |name| {
                    try writer.writeAll(name);
                }
            },
        },
        .conditional => |conditional| {
            if (switch (conditional.name) {
                .written, .title, .file, .back_text => true,
                .dir => file.dir != null,
                .back, .parent => file.dir != null or
                    !std.mem.eql(u8, file.name, "index"),
                .updated => info.changes.len > 0,
                .parent_name => file.parent_title != null,
            }) {
                try formatTemplate(conditional.output, info, file, writer);
            }
        },
    };
}

// ---- UTILS ----

/// Gets all of the process's args, kindly splitting shortform options like
/// -oPt into -o -P -t to make parsing easier.
/// Caller owns both the outer and inner slices
fn getArgs(
    allocator: *std.mem.Allocator,
) ![]const []const u8 {
    var args = std.ArrayList([]const u8).init(allocator);
    errdefer args.deinit();
    errdefer for (args.items) |arg| allocator.free(arg);
    var it = std.process.ArgIterator.init();
    defer it.deinit();
    while (it.next(allocator)) |next_or_err| {
        const arg = try next_or_err;
        defer allocator.free(arg);
        if (std.mem.startsWith(u8, arg, "-") and
            !std.mem.startsWith(u8, arg, "--") and
            arg.len > 2)
        {
            for (arg[1..]) |char| {
                const buffer = try allocator.alloc(u8, 2);
                buffer[0] = '-';
                buffer[1] = char;
                try args.append(buffer[0..]);
            }
        } else {
            try args.append(try allocator.dupe(u8, arg));
        }
    }
    return args.toOwnedSlice();
}

/// Check if an arg equals the given longform or shortform
fn getOpt(
    arg: []const u8,
    comptime long: []const u8,
    comptime short: ?u8,
) bool {
    if (short) |char| {
        if (std.mem.eql(u8, arg, "-" ++ &[1]u8{char})) {
            return true;
        }
    }
    return std.mem.eql(u8, arg, "--" ++ long);
}

/// Returns false if it hit the end of the stream
fn readLine(reader: anytype, array_list: *std.ArrayList(u8)) !bool {
    while (reader.readByte()) |byte| {
        if (byte == '\n') return true;
        try array_list.append(byte);
    } else |err| switch (err) {
        error.EndOfStream => {
            if (array_list.items.len > 0) return true else return false;
        },
        else => |other_err| return other_err,
    }
}

/// Using this line reader to consume documents is pretty important, because this
/// is the stage where private lines are skipped over.
/// Caller owns result
fn readLines(
    reader: anytype,
    allocator: *std.mem.Allocator,
) ![]const []const u8 {
    var lines = std.ArrayList([]const u8).init(allocator);
    var current_line = std.ArrayList(u8).init(allocator);
    while (try readLine(reader, &current_line)) {
        if (std.mem.startsWith(u8, current_line.items, "; ")) {
            if (include_private) {
                try lines.append(current_line.toOwnedSlice()[2..]);
            } else {
                current_line.shrinkRetainingCapacity(0);
            }
        } else {
            try lines.append(current_line.toOwnedSlice());
        }
    }
    return lines.toOwnedSlice();
}

fn parseLiteral(
    text: []const u8,
    start: usize,
    literal: []const u8,
) ?usize {
    if (start >= text.len) return null;
    if (!std.mem.startsWith(u8, text[start..], literal)) return null;
    return start + literal.len;
}

const Whitespace = struct {
    size: usize,
    pub fn format(self: @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        var i: usize = 0;
        while (i < self.size) : (i += 1) try writer.writeByte(' ');
    }
};
