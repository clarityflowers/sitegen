const std = @import("std");
const log = std.log.scoped(.website);
const Date = @import("zig-date/src/main.zig").Date;

const Dir = struct {
    src: []const u8,
    dest: []const u8,
};

var include_private = false;
var env_map: std.BufMap = undefined;

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit()) log.debug("Detected memory leak.", .{});

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
        \\  make  The main generation tool
        \\  index  Outputs site indexes in various formats
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
    } else {
        log.alert("Unknown command {s}", .{args[1]});
        try stdout.print(help, .{exe_name});
    }
}

fn make(
    exe_name: []const u8,
    args: []const []const u8,
    allocator: *std.mem.Allocator,
) !void {
    var cwd = std.fs.cwd();

    var index: usize = 0;
    const usage =
        \\usage:
        \\  {0s} make [-p] [--private] [--] <out_dir> [<site_dir>]
        \\  {0s} make [--help]
        \\
    ;
    const help = usage ++
        \\
        \\arguments:
        \\  out_dir   the output folder for all generated content
        \\  site_dir  the input folder for the site itself, defaults to cwd
        \\options:
        \\  --help    show this text
        \\  -p, --private  include private content in the build
    ;
    if (args.len == 0) {
        try std.io.getStdOut().writer().print(usage, .{exe_name});
        return;
    }
    while (index < args.len) : (index += 1) {
        if (getOpt(args[index], "private", 'p')) {
            include_private = true;
            try env_map.set("INCLUDE_PRIVATE", "true");
        } else if (getOpt(args[index], "help", null)) {
            try std.io.getStdOut().writer().print(help, .{exe_name});
            return;
        } else if (getOpt(args[index], "", null)) {
            index += 1;
            break;
        } else if (std.mem.startsWith(u8, args[index], "-")) {
            log.alert("Unknown arg {s}", .{args[index]});
            return error.BadArgs;
        } else {
            break;
        }
    }
    if (index >= args.len) {
        log.alert("Missing <out_dir> argument.", .{});
        try std.io.getStdOut().writer().print(usage, .{exe_name});
        return error.BadArgs;
    }
    try cwd.makePath(args[index]);
    var out_dir = try cwd.openDir(args[index], .{});
    defer out_dir.close();
    try out_dir.makePath("html");
    try out_dir.makePath("gmi");
    var html_dir = try out_dir.openDir("html", .{});
    defer html_dir.close();
    var gmi_dir = try out_dir.openDir("gmi", .{});
    defer gmi_dir.close();
    index += 1;
    var site_dir = try cwd.openDir(
        if (index < args.len) args[index] else ".",
        .{ .iterate = true },
    );
    // Ensures that child processes work as you might expect
    try site_dir.setAsCwd();
    defer site_dir.close();
    try renderDir(&site_dir, null, &html_dir, &gmi_dir, allocator);
    var it = site_dir.iterate();
    while (try it.next()) |item| {
        if (item.kind != .Directory) continue;
        try renderDir(
            &site_dir,
            item.name,
            &html_dir,
            &gmi_dir,
            allocator,
        );
    }

    log.info("Done!", .{});
}

fn renderDir(
    site_dir: *std.fs.Dir,
    dirname: ?[]const u8,
    html_dir: *std.fs.Dir,
    gmi_dir: *std.fs.Dir,
    allocator: *std.mem.Allocator,
) !void {
    const dir_path = dirname orelse ".";
    var src_dir = try site_dir.openDir(
        dir_path,
        .{ .iterate = true },
    );
    try src_dir.setAsCwd();
    defer src_dir.close();
    var it = src_dir.iterate();
    while (try it.next()) |item| {
        if (item.kind != .File) continue;
        var arena = std.heap.ArenaAllocator.init(allocator);
        log.info("Generating {s}/{s}", .{
            dir_path,
            item.name,
        });
        defer arena.deinit();
        const src_file = try src_dir.openFile(item.name, .{});
        defer src_file.close();
        const lines = try readLines(src_file.reader(), &arena.allocator);
        const doc = try parseDocument(lines, item.name, &arena.allocator);
        if (doc.info.private and !include_private) continue;
        {
            try html_dir.makePath(dir_path);
            var dir = try html_dir.openDir(dir_path, .{});
            defer dir.close();
            const out_filename = try std.mem.concat(
                &arena.allocator,
                u8,
                &[_][]const u8{ item.name, ".html" },
            );
            const out_file = try dir.createFile(
                out_filename,
                .{ .truncate = true },
            );
            defer out_file.close();
            try formatHtml(doc, out_file.writer(), dirname, item.name);
        }
        {
            try gmi_dir.makePath(dir_path);
            var dir = try gmi_dir.openDir(dir_path, .{});
            defer dir.close();
            const out_filename = try std.mem.concat(
                &arena.allocator,
                u8,
                &[_][]const u8{ item.name, ".gmi" },
            );
            const out_file = try dir.createFile(
                out_filename,
                .{ .truncate = true },
            );
            defer out_file.close();
            try formatGmi(doc, out_file.writer(), true);
        }
    }
}

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
        error.EndOfStream => return false,
        else => |other_err| return other_err,
    }
}

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
    if (current_line.items.len > 0) {
        try lines.append(current_line.toOwnedSlice());
    }
    return lines.toOwnedSlice();
}

// ---- MODELS ----

const Ext = enum {
    html, gmi
};

const Document = struct {
    blocks: []const Block,
    info: Info,
};

const Info = struct {
    title: []const u8,
    created: Date,
    updated: ?Date = null,
    private: bool = false,
};

const Page = struct {
    filename: []const u8,
    info: Info,
};

const Block = union(enum) {
    paragraph: []const Span,
    raw: Raw,
    heading: []const u8,
    subheading: []const u8,
    quote: []const []const Span,
    list: []const []const Span,
    links: []const Link,
    unknown_command: []const u8,
    preformatted: []const []const u8,
};

const Raw = struct {
    ext: Ext,
    lines: []const []const u8,
};

const Image = struct {
    url: []const u8,
    text: []const u8,
    destination: ?[]const u8,
};

const Link = struct {
    url: []const u8,
    text: ?[]const u8 = null,
    auto_ext: bool = false,
};

const Span = union(enum) {
    text: []const u8,
    strong: []const Span,
    emphasis: []const Span,
    anchor: Anchor,
    br,
};

const Anchor = struct {
    url: []const u8,
    text: []const Span,
};

// ---- PARSING ----

fn parseDocument(
    lines: []const []const u8,
    path: []const u8,
    allocator: *std.mem.Allocator,
) !Document {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var errarena = std.heap.ArenaAllocator.init(allocator);
    errdefer errarena.deinit();

    const info_res = try parseInfo(lines);
    const blocks = try parseBlocks(lines, info_res.new_pos, &errarena.allocator);

    const result: Document = .{
        .blocks = blocks,
        .info = info_res.data,
    };
    return result;
}

// wow so many things can go wrong with computers
const ParseError = error{
    ProcessEndedUnexpectedly,
    SpanNotClosed,
} || std.mem.Allocator.Error ||
    std.process.GetEnvVarOwnedError || std.fs.File.ReadError ||
    std.fs.File.WriteError || std.ChildProcess.SpawnError;

fn ParseResult(comptime Type: type) type {
    return struct {
        data: Type,
        new_pos: usize,
    };
}

fn ok(data: anytype, new_pos: usize) ParseResult(@TypeOf(data)) {
    return .{
        .data = data,
        .new_pos = new_pos,
    };
}

fn parseTitle(reader: anytype, allocator: *std.mem.Allocator) ![]const u8 {
    return try reader.readUntilDelimiterAlloc(allocator, '\n', 1024);
}

fn parseInfo(lines: []const []const u8) !ParseResult(Info) {
    comptime const created_prefix = "Written";
    comptime const updated_prefix = "Updated";
    if (lines.len == 0) return error.NoInfo;
    const title = lines[0];
    var created: ?Date = null;
    var updated: ?Date = null;
    var line: usize = 1;
    var private = false;
    while (line < lines.len and lines[line].len > 0) : (line += 1) {
        if (std.mem.startsWith(u8, lines[line], created_prefix ++ " ")) {
            created = try Date.parse(lines[line][created_prefix.len + 1 ..]);
        } else if (std.mem.startsWith(u8, lines[line], updated_prefix ++ " ")) {
            updated = try Date.parse(lines[line][updated_prefix.len + 1 ..]);
        } else if (std.mem.eql(u8, lines[line], "Private")) {
            private = true;
        } else {
            log.alert("Could not parse info on line {}:", .{line});
            log.alert("{s}", .{lines[line]});
            return error.UnexpectedInfo;
        }
    }
    return ok(Info{
        .title = title,
        .created = created orelse return error.NoCreatedDate,
        .updated = updated,
        .private = private,
    }, line);
}

fn parseBlocks(
    lines: []const []const u8,
    start: usize,
    allocator: *std.mem.Allocator,
) ParseError![]const Block {
    var index = start;
    var blocks = std.ArrayList(Block).init(allocator);
    var spans = std.ArrayList(Span).init(allocator);
    while (index < lines.len) {
        if (try parseCommand(lines, index, allocator)) |res| {
            if (spans.items.len > 0) {
                try blocks.append(.{ .paragraph = spans.toOwnedSlice() });
            }
            try blocks.appendSlice(res.data);
            index = res.new_pos;
        } else if (try parseBlock(lines, index, allocator)) |res| {
            if (spans.items.len > 0) {
                try blocks.append(.{ .paragraph = spans.toOwnedSlice() });
            }
            try blocks.append(res.data);
            index = res.new_pos;
        } else if (spans.items.len > 0 and lines[index].len == 0) {
            try blocks.append(.{ .paragraph = spans.toOwnedSlice() });
            index += 1;
        } else if (try parseSpans(lines[index], 0, null, null, allocator)) |res| {
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

fn parseCommand(
    lines: []const []const u8,
    start: usize,
    allocator: *std.mem.Allocator,
) !?ParseResult([]const Block) {
    if (try parsePrefixedLines(
        lines,
        start,
        ":",
        allocator,
    )) |res| {
        const shell = try std.process.getEnvVarOwned(allocator, "SHELL");

        var process = try std.ChildProcess.init(
            &[_][]const u8{shell},
            allocator,
        );
        defer process.deinit();
        process.env_map = &env_map;
        process.stdin_behavior = .Pipe;
        process.stdout_behavior = .Pipe;

        try process.spawn();
        errdefer _ = process.kill() catch |err| {
            log.warn("Had trouble cleaning up process: {}", .{err});
        };
        const writer = process.stdin.?.writer();
        for (res.data) |line| {
            try writer.print("{s}\n", .{line});
        }
        process.stdin.?.close();
        process.stdin = null;

        const result_lines = try readLines(
            process.stdout.?.reader(),
            allocator,
        );
        switch (try process.wait()) {
            .Exited => return ok(
                try parseBlocks(result_lines, 0, allocator),
                res.new_pos,
            ),
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
    if (try parseRaw(lines, line, allocator)) |res| {
        return ok(Block{ .raw = res.data }, res.new_pos);
    } else if (try parsePrefixedLines(lines, line, " ", allocator)) |res| {
        return ok(Block{ .preformatted = res.data }, res.new_pos);
    } else if (try parseWrapper(lines, line, "> ", allocator)) |res| {
        return ok(Block{ .quote = res.data }, res.new_pos);
    } else if (parseHeading(lines[line])) |heading| {
        return ok(Block{ .heading = heading }, line + 1);
    } else if (parseSubheading(lines[line])) |subheading| {
        return ok(Block{ .subheading = subheading }, line + 1);
    } else if (try parseLinks(lines, line, allocator)) |res| {
        return ok(Block{ .links = res.data }, res.new_pos);
    } else if (try parseList(lines, line, allocator, "- ")) |res| {
        return ok(Block{ .list = res.data }, res.new_pos);
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
    while (line < lines.len and std.mem.startsWith(
        u8,
        lines[line],
        prefix ++ " ",
    )) : (line += 1) {
        try result.append(lines[line][prefix.len + 1 ..]);
    }
    return ok(@as([]const []const u8, result.toOwnedSlice()), line);
}

fn parseHeading(line: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, line, "# ")) return line[2..];
    return null;
}

fn parseSubheading(line: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, line, "## ")) return line[3..];
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

fn parseLinks(
    lines: []const []const u8,
    start: usize,
    allocator: *std.mem.Allocator,
) !?ParseResult([]const Link) {
    var line = start;
    var result = std.ArrayList(Link).init(allocator);
    while (line < lines.len and
        std.mem.startsWith(u8, lines[line], "=> ")) : (line += 1)
    {
        const url_end = std.mem.indexOfPos(
            u8,
            lines[line],
            3,
            " ",
        ) orelse return null;
        const text = lines[line][url_end + 1 ..];
        const url = lines[line][3..url_end];

        if (std.mem.endsWith(u8, url, ".*")) {
            try result.append(.{
                .url = url[0 .. url.len - 2],
                .text = text,
                .auto_ext = true,
            });
        } else {
            try result.append(.{
                .url = url,
                .text = text,
            });
        }
    }
    if (result.items.len == 0) return null;
    return ok(@as([]const Link, result.toOwnedSlice()), line);
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

fn parseParagraph(
    lines: []const []const u8,
    l: usize,
    prefix: ?[]const u8,
    allocator: *std.mem.Allocator,
) !?ParseResult([]const Span) {
    var start = l;
    while (lines[start].len == 0) {
        start += 1;
    }
    var spans = std.ArrayList(Span).init(allocator);
    errdefer spans.deinit();
    const end = for (lines[start..]) |line, index| {
        if (line.len == 0 or
            line[0] == '!' or
            std.mem.startsWith(u8, line, "# ") or
            std.mem.startsWith(u8, line, "~ ") or
            std.mem.startsWith(u8, line, "- ") or
            std.mem.startsWith(u8, line, "  "))
        {
            if (index == 0) {
                return null;
            }
            break start + index;
        } else {
            const result = (try parseSpans(line, 0, allocator, null)) orelse
                continue;
            if (index != 0) {
                try spans.append(.br);
            }
            try spans.appendSlice(result.data);
        }
    } else lines.len;
    const data = spans.toOwnedSlice();
    for (data) |span| {}
    return ParseResult([]const Span){
        .data = data,
        .new_pos = end,
    };
}
fn parseSpans(
    line: []const u8,
    start: usize,
    comptime open: ?[]const u8,
    comptime close: ?[]const u8,
    allocator: *std.mem.Allocator,
) ParseError!?ParseResult([]const Span) {
    var col = start;
    if (open) |match| {
        if (!std.mem.startsWith(u8, line[col..], match)) return null;
        col += match.len;
    }
    var spans = std.ArrayList(Span).init(allocator);
    var text = std.ArrayList(u8).init(allocator);
    while (col < line.len) {
        if (close) |match| {
            if (std.mem.startsWith(u8, line[col..], match)) {
                break;
            }
        }
        if (try parseSpan(line, col, allocator)) |res| {
            if (text.items.len > 0) {
                try spans.append(.{ .text = text.toOwnedSlice() });
            }
            try spans.append(res.data);
            col += res.new_pos;
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

fn formatDoc(
    doc: Document,
    writer: anytype,
    ext: Ext,
    back_text: ?[]const u8,
    include_dates: bool,
) !void {
    switch (ext) {
        .html => return formatHtml(doc, writer, back_text, include_dates),
        .gmi => return formatGmi(doc, writer, include_dates),
    }
}

// ---- HTML FORMATTING ----

pub fn formatHtml(
    doc: Document,
    writer: anytype,
    dirname: ?[]const u8,
    filename: []const u8,
) !void {
    try writer.writeAll(html_preamble);
    try writer.print("<title>{0s} ~ Clarity's Blog</title>\n", .{doc.info.title});
    try writer.writeAll(
        \\</head>
        \\<body>
        \\
    );
    if (dirname) |dir| {
        if (std.mem.eql(u8, filename, "index")) {
            try writer.writeAll("<a href=\"..\">return home</a>");
        } else {
            try writer.print(
                "<a href=\".\">{s} index</a>\n",
                .{dir},
            );
        }
    } else if (!std.mem.eql(u8, filename, "index")) {
        try writer.writeAll("<a href=\".\">return home</a>");
    }
    try writer.writeAll("<main>\n");
    try writer.print(
        \\<header>
        \\  <h1>{s}</h1>
        \\
    , .{doc.info.title});
    try writer.print("Written {Month D, YYYY}", .{doc.info.created});
    if (doc.info.updated) |updated| {
        try writer.print(", updated {Month D, YYYY}", .{updated});
    }

    try writer.writeAll(
        \\
        \\</header>
        \\
    );
    for (doc.blocks) |block| try formatBlockHtml(block, writer);
    try writer.writeAll(
        \\</main>
        \\<footer>
        \\<p> 
        \\  This color palette is 
        \\  <a href="https://www.colourlovers.com/palette/2598543/Let_Me_Be_Myself_*">
        \\    Let Me Be Myself *
        \\  </a>
        \\  by 
        \\  <a href="https://www.colourlovers.com/lover/sugar%21">sugar!</a>. 
        \\  License: 
        \\  <a href="https://creativecommons.org/licenses/by-nc-sa/3.0/">
        \\    CC-BY-NC-SA 3.0
        \\  </a>.
        \\</p>
        \\</body>
        \\</html>
        \\
    );
}

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
            try writer.print("\">{s}</h2>\n", .{heading});
        },
        .subheading => |subheading| {
            try writer.writeAll("<h3 id=\"");
            try formatId(subheading, writer);
            try writer.print("\">{s}</h2>\n", .{subheading});
        },
        .raw => |raw| switch (raw.ext) {
            .html => for (raw.lines) |line| try writer.print("{s}\n", .{line}),
            else => {},
        },
        .links => |links| {
            for (links) |link| {
                const text = link.text orelse link.url;
                try writer.print("<a href=\"{s}", .{link.url});
                if (link.auto_ext) {
                    try writer.writeAll(".html");
                }
                try writer.print("\">{s}</a>\n", .{
                    link.text,
                });
            }
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
                try writer.print("{s}\n", .{line});
            }
            try writer.writeAll("</pre>\n");
        },
        .unknown_command => |command| {
            try writer.print("UNKNOWN COMMAND: {s}\n", .{command});
        },
    }
}

fn formatSpanHtml(span: Span, writer: anytype) @TypeOf(writer).Error!void {
    switch (span) {
        .text => |text| {
            try writer.writeAll(text);
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

// ---- GEMINI FORMATTING ----

pub fn formatGmi(
    doc: Document,
    writer: anytype,
    include_writing_dates: bool,
) !void {
    try writer.print("# {s}\n", .{doc.info.title});
    if (include_writing_dates) {
        try writer.print("Written {Month D, YYYY}", .{doc.info.created});
        if (doc.info.updated) |updated| {
            try writer.print(", updated {Month D, YYYY}", .{updated});
        }
    }
    try writer.writeAll("\n");
    for (doc.blocks) |block| try formatBlockGmi(block, writer);
    try writer.writeAll("\n");
}

fn formatParagraphGmi(
    spans: []const Span,
    prefix: []const u8,
    writer: anytype,
) !void {
    try writer.writeAll(prefix);
    for (spans) |span| {
        if (span == .br) try writer.writeAll(prefix);
        try formatSpanGmi(span, writer);
    }
    try writer.writeAll("\n\n");
}

fn formatBlockGmi(
    block: Block,
    writer: anytype,
) @TypeOf(writer).Error!void {
    switch (block) {
        .paragraph => |paragraph| {
            try formatParagraphGmi(paragraph, "", writer);
        },
        .heading => |heading| {
            try writer.print("## {s}\n\n", .{heading});
        },
        .subheading => |subheading| {
            try writer.print("### {s}\n\n", .{subheading});
        },
        .raw => |raw| switch (raw.ext) {
            .gmi => for (raw.lines) |line| {
                try writer.print("{s}\n", .{line});
            },
            else => {},
        },
        .links => |links| {
            for (links) |link| {
                try writer.print("=> {s}", .{link.url});
                if (link.auto_ext) {
                    try writer.writeAll(".gmi");
                }
                if (link.text) |text| {
                    try writer.print(" {s}", .{text});
                }
                try writer.writeByte('\n');
            }
            try writer.writeByte('\n');
        },
        .list => |list| {
            for (list) |item| {
                try writer.writeAll("* ");
                for (item) |span| try formatSpanGmi(span, writer);
                try writer.writeAll("\n");
            }
            try writer.writeAll("\n");
        },
        .quote => |paragraphs| {
            for (paragraphs) |p| {
                try formatParagraphGmi(p, "> ", writer);
            }
        },
        .preformatted => |lines| {
            try writer.writeAll("```\n");
            for (lines) |line| {
                try writer.print("{s}\n", .{line});
            }
            try writer.writeAll("```\n\n");
        },
        .unknown_command => |command| {
            try writer.print("UNKNOWN COMMAND: {s}\n", .{command});
        },
    }
}

fn formatSpanGmi(span: Span, writer: anytype) @TypeOf(writer).Error!void {
    switch (span) {
        .text => |text| try writer.writeAll(text),
        .emphasis,
        .strong,
        => |spans| for (spans) |sp| try formatSpanGmi(sp, writer),
        .anchor => |anchor| for (anchor.text) |sp|
            try formatSpanGmi(sp, writer),
        .br => try writer.writeAll("\n"),
    }
}

// ---- INDEXING ----

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
        \\  {0s} index [-p] [--private] [--] <file> [<file>...]
    ;
    const stdout = std.io.getStdOut().writer();
    if (args.len == 0) {
        try stdout.print(usage, .{exe_name});
        return;
    }
    while (arg_i < args.len) : (arg_i += 1) {
        const arg = args[arg_i];
        if (getOpt(arg, "private", 'p')) {
            include_private = true;
        } else if (getOpt(arg, "help", null)) {
            try stdout.print(usage, .{exe_name});
            return;
        } else if (getOpt(arg, "-", null)) {
            arg_i += 1;
            break;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            log.alert("Unknown argument {}", .{arg});
            return error.BadArgs;
        } else break;
    }
    if (arg_i >= args.len) {
        log.alert("Missing argument <file>.", .{});
        try stdout.print(usage, .{exe_name});
        return;
    }
    var files = std.ArrayList([]const u8).init(&arena.allocator);
    while (arg_i < args.len) : (arg_i += 1) {
        try files.append(args[arg_i]);
    }
    const cwd = std.fs.cwd();
    var pages = std.ArrayList(Page).init(&arena.allocator);
    for (files.items) |filename| {
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
        var info = (try parseInfo(lines)).data;
        if (info.private and !include_private) continue;
        try pages.append(.{ .filename = filename, .info = info });
    }
    const sortFn = struct {
        fn earlierThan(context: void, lhs: Page, rhs: Page) bool {
            return lhs.info.created.isBefore(rhs.info.created);
        }
    }.earlierThan;
    try formatIndexMarkup(stdout, pages.items);
}

fn formatIndexMarkup(writer: anytype, pages: []const Page) !void {
    for (pages) |page| {
        if (page.info.private) {
            try writer.writeAll("; ");
        }
        try writer.print("=> {s}.* {} – {s}\n", .{
            page.filename,
            page.info.created,
            page.info.title,
        });
    }
}
