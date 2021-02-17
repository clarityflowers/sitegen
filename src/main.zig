/// All of the source code for this project lives in this file.
///
/// Its layout looks like this:
/// - entry point
/// - make        document generating
/// - models      data structures representing documents
/// - parsing     reading source documents into the models
/// - formatting  writing the models in the target format
/// - indexing    formatting lists of documents
/// - utils       common functions that I didn't have another place for
///
/// If you want to add new features, you'll need to add the new block/span type
/// to the union, add the appropriate parser in the "parsing" section and hook it /// into the parsing flow. Then, in the formatting section, add handlers for your
/// new union fields for both targets
///
/// If you want to change the templates documents render into, that's in
/// formatHtml() and formatGmi().
///
const std = @import("std");
const log = std.log.scoped(.website);
const Date = @import("zig-date/src/main.zig").Date;

/// Global variables aren't too hard to keep track of when you only have one file.
var include_private = false;
var env_map: std.BufMap = undefined;

/// Entry point for the application
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
        \\  make   The main generation tool
        \\  index  Outputs site indexes in various formats
        \\  docs   Print the sitegen documentation in sitegen format
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
        try stdout.writeAll(@embedFile("docs"));
    } else {
        log.alert("Unknown command {s}", .{args[1]});
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
        \\  --help         show this text
        \\  -p, --private  include private content in the build
    ;
    if (args.len == 0) {
        try std.io.getStdOut().writer().print(usage, .{exe_name});
        return;
    }
    while (index < args.len) : (index += 1) {
        if (getOpt(args[index], "private", 'p')) {
            include_private = true;
            try env_map.set("INCLUDE_PRIVATE", "--private");
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

/// Iterate over all files in a directory and render their output for each target
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

// ---- MODELS ----

/// The possible rendering targets
const Ext = enum {
    html, gmi
};

/// A parsed document
const Document = struct {
    blocks: []const Block,
    info: Info,
};

/// The metadata at the top of the document
const Info = struct {
    title: []const u8,
    created: Date,
    changes: []const Change,
    private: bool = false,
};

const Change = struct {
    date: Date,
    what_changed: ?[]const u8 = null,
};

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
};

/// Text that should be copied as-is into the output IF the current rendering
/// target matches the extension
const Raw = struct {
    ext: Ext,
    lines: []const []const u8,
};

/// A line-level link
const Link = struct {
    url: []const u8,
    text: ?[]const u8 = null,
    auto_ext: bool = false,
};

/// Inline formatting. Pretty much ignored entirely by gemini.
const Span = union(enum) {
    text: []const u8,
    strong: []const Span,
    emphasis: []const Span,
    anchor: Anchor,
    br,
};

/// An inline link.
const Anchor = struct {
    url: []const u8,
    text: []const Span,
};

// ---- PARSING ----

/// I have a specific parsing model I like to use that works pretty well for me.
/// First, all of the document is split into a span of text lines. If a parsing
/// function could consume multiple lines, it takes all of the lines (including
/// those already consumed) along with a start index, then returns the resulting
/// structure along with the new index if it found a match. If no match was found
/// it returns null.
/// What I like about this is that we always have the context of the current line
/// number close on hand so that if we need to put out helpful log messages, we
/// can, and it's easy to right "speculative parsers" that go along doing their
/// to parse a format, but can "rewind" harmlessly if something goes wrong.
/// In general, this also means that errors don't really happen, because if you
/// mistype something it'll usually just fall back to raw text.
fn parseDocument(
    lines: []const []const u8,
    path: []const u8,
    allocator: *std.mem.Allocator,
) !Document {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var errarena = std.heap.ArenaAllocator.init(allocator);
    errdefer errarena.deinit();

    const info_res = try parseInfo(lines, allocator);
    const blocks = try parseBlocks(lines, info_res.new_pos, &errarena.allocator);

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
) !ParseResult(Info) {
    comptime const created_prefix = "Written ";
    comptime const updated_prefix = "Updated ";
    if (lines.len == 0) return error.NoInfo;
    const title = lines[0];
    var created: ?Date = null;
    var changes = std.ArrayList(Change).init(allocator);
    errdefer changes.deinit();
    var line: usize = 1;
    var private = false;
    while (line < lines.len and lines[line].len > 0) : (line += 1) {
        if (std.mem.startsWith(u8, lines[line], created_prefix)) {
            created = try Date.parse(lines[line][created_prefix.len..]);
        } else if (std.mem.startsWith(u8, lines[line], updated_prefix)) {
            var date = try Date.parse(lines[line][updated_prefix.len..]);
            const what_changed_start = updated_prefix.len + "0000-00-00".len + 1;
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
        } else {
            log.alert("Could not parse info on line {}:", .{line});
            log.alert("{s}", .{lines[line]});
            return error.UnexpectedInfo;
        }
    }
    return ok(Info{
        .title = title,
        .created = created orelse return error.NoCreatedDate,
        .changes = changes.toOwnedSlice(),
        .private = private,
    }, line);
}

/// The basic idea for blocks is: if it's not anything else, it's a paragraph.
/// So, we try to parse various block patterns, and if nothing matches, we
/// add a line of paragraph text which will be "flushed out" as soon as something
/// DOES match (or the end of the file).
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

/// This is the fun stuff. Everything written inside of a command block is piped
/// into the shell, and the output is then parsed as blocks like any other
/// content. Not very much code and A LOT of power.
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
        defer allocator.free(res.data);
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
            .Exited => |status| {
                if (status != 0) {
                    log.alert("Process ended unexpectedly on line {d}", .{
                        res.new_pos,
                    });
                    return error.ProcessEndedUnexpectedly;
                }
                return ok(
                    try parseBlocks(result_lines, 0, allocator),
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

fn parseLink(line: []const u8) !?Link {
    if (!std.mem.startsWith(u8, line, "=> ")) return null;
    const url_end = std.mem.indexOfPos(
        u8,
        line,
        3,
        " ",
    ) orelse return null;
    const text = line[url_end + 1 ..];
    const url = line[3..url_end];

    if (std.mem.endsWith(u8, url, ".*")) {
        return Link{
            .url = url[0 .. url.len - 2],
            .text = text,
            .auto_ext = true,
        };
    } else {
        return Link{
            .url = url,
            .text = text,
        };
    }
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

/// Writes the document for the given render target.
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

/// If you want a differnt html template, because you don't want "Clarity Flowers"
/// in the titlebar, this is the function you need to edit :)
pub fn formatHtml(
    doc: Document,
    writer: anytype,
    dirname: ?[]const u8,
    filename: []const u8,
) !void {
    try writer.writeAll(html_preamble);
    try writer.print("<title>{0s} ~ Clarity Flowers</title>\n", .{
        doc.info.title,
    });
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
    if (doc.info.changes.len > 0) {
        try writer.print(", last changed {Month D, YYYY}", .{
            doc.info.changes[doc.info.changes.len - 1].date,
        });
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
        \\<p><a href="gemini://clarity.flowers
    );
    if (dirname) |dir| {
        try writer.print("/{s}", .{dirname});
    }
    if (!std.mem.eql(u8, filename, "index")) {
        try writer.print("/{s}.gmi", .{filename});
    }
    try writer.writeAll(
        \\">This page is also available on gemini.</a>
        \\(<a href="/wiki/gemini.html">What is gemini?</a>)
        \\</p>
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
            const text = HtmlText.init(link.text orelse link.url);
            const url = HtmlText.init(link.url);
            try writer.print("<a href=\"{s}", .{url});
            if (link.auto_ext) {
                try writer.writeAll(".html");
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

/// Gemini is SO MUCH EASIER to generate, god.
pub fn formatGmi(
    doc: Document,
    writer: anytype,
    include_writing_dates: bool,
) !void {
    try writer.print("# {s}\n", .{doc.info.title});
    if (include_writing_dates) {
        try writer.print("Written {Month D, YYYY}", .{doc.info.created});
        if (doc.info.changes.len > 0) {
            try writer.print(", last changed {Month D, YYYY}", .{
                doc.info.changes[doc.info.changes.len - 1].date,
            });
        }
    }
    try writer.writeAll("\n\n");
    for (doc.blocks) |block| try formatBlockGmi(block, writer);
    try writer.writeAll("\n");
}

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
            try writer.writeAll("\n");
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
            try writer.writeAll("```\n\n");
        },
        .empty => {
            try writer.writeAll("\n");
        },
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
            try stdout.print(help, .{exe_name});
            return;
        } else if (getOpt(arg, "limit", 'l')) {
            arg_i += 1;
            limit = std.fmt.parseInt(usize, args[arg_i], 10) catch {
                log.alert("Limit value must be positive integer, got: {s}", .{
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
    var pages = std.ArrayList(IndexEntry).init(&arena.allocator);
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
        var info = (try parseInfo(lines, allocator)).data;
        defer allocator.free(info.changes);
        if (info.private and !include_private) continue;
        if (include_updates) {
            for (info.changes) |change| {
                try pages.append(.{
                    .filename = filename,
                    .info = info,
                    .event = .{ .updated = change.what_changed },
                    .date = change.date,
                });
            }
        }
        if (include_additions) {
            try pages.append(.{
                .filename = filename,
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
        try writer.print("=> {s}.* {} – {s}", .{
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
        error.EndOfStream => return false,
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
    if (current_line.items.len > 0) {
        try lines.append(current_line.toOwnedSlice());
    }
    return lines.toOwnedSlice();
}
