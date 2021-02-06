const std = @import("std");
const log = std.log.scoped(.website);
const Date = @import("zig-date/src/main.zig").Date;

const Dir = struct {
    src: []const u8,
    dest: []const u8,
};

var include_private = false;

pub fn main() anyerror!void {
    log.info("Hello!", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit()) log.debug("Detected memory leak.", .{});

    inline for (@typeInfo(Ext).Enum.fields) |fld| {
        try std.fs.cwd().makePath(fld.name);
    }

    const args = try std.process.argsAlloc(&gpa.allocator);
    defer std.process.argsFree(&gpa.allocator, args);

    include_private = args.len > 1 and
        (std.mem.eql(u8, args[1], "-p") or std.mem.eql(u8, args[1], "--private"));

    const cwd = std.fs.cwd();

    {
        var arena = std.heap.ArenaAllocator.init(&gpa.allocator);
        defer arena.deinit();
        var blog_dir = try cwd.openDir("blog", .{ .iterate = true });
        defer blog_dir.close();

        const files = try getFiles(&blog_dir, &arena.allocator);

        try renderFiles(
            &blog_dir,
            files,
            "blog",
            "gemlog",
            "blog index",
            true,
            &gpa.allocator,
        );
        {
            const blog_index_file = try cwd.createFile("html/blog/index.html", .{
                .truncate = true,
            });
            defer blog_index_file.close();
            const writer = blog_index_file.writer();
            try formatBlogIndexHtml(files, writer);
        }
        {
            const blog_index_file = try cwd.createFile(
                "gmi/gemlog/index.gmi",
                .{
                    .truncate = true,
                },
            );
            defer blog_index_file.close();
            const writer = blog_index_file.writer();
            try formatBlogIndexGmi(files, writer);
        }
    }
    {
        var arena = std.heap.ArenaAllocator.init(&gpa.allocator);
        defer arena.deinit();
        var home_dir = try cwd.openDir("home", .{ .iterate = true });
        defer home_dir.close();

        const files = try getFiles(&home_dir, &arena.allocator);

        try renderFiles(
            &home_dir,
            files,
            ".",
            ".",
            null,
            false,
            &gpa.allocator,
        );
    }
    {
        var arena = std.heap.ArenaAllocator.init(&gpa.allocator);
        defer arena.deinit();
        var wiki_dir = try cwd.openDir("wiki", .{ .iterate = true });
        defer wiki_dir.close();

        const files = try getFiles(&wiki_dir, &arena.allocator);

        try renderFiles(
            &wiki_dir,
            files,
            "wiki",
            "wiki",
            "wiki index",
            false,
            &gpa.allocator,
        );
    }
    log.info("Done!", .{});
}

/// Caller owns the returned files
fn getFiles(
    src_dir: *std.fs.Dir,
    allocator: *std.mem.Allocator,
) ![]const Page {
    var iterator = src_dir.iterate();
    var pages = std.ArrayList(Page).init(allocator);
    while (try iterator.next()) |entry| {
        if (entry.kind == .File) {
            const file = try src_dir.openFile(entry.name, .{});
            defer file.close();
            const info = blk: {
                var lines = std.ArrayList([]const u8).init(allocator);
                var line = std.ArrayList(u8).init(allocator);
                while (true) {
                    try file.reader().readUntilDelimiterArrayList(
                        &line,
                        '\n',
                        256,
                    );
                    if (line.items.len == 0) break;
                    try lines.append(line.toOwnedSlice());
                }
                const res = try parseInfo(lines.items);
                if (!include_private and res.data.private) {
                    lines.deinit();
                    continue;
                }
                break :blk res.data;
            };
            const filename = try allocator.dupe(u8, entry.name);
            try pages.append(.{
                .filename = filename,
                .info = info,
            });
        }
    }
    return pages.toOwnedSlice();
}

/// All allocated memory is freed before function completes
fn renderFiles(
    src_dir: *std.fs.Dir,
    files: []const Page,
    html_out_path: []const u8,
    gmi_out_path: []const u8,
    back_text: ?[]const u8,
    include_dates: bool,
    allocator: *std.mem.Allocator,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    for (files) |page| {
        const lines = blk: {
            const file = try src_dir.openFile(
                page.filename,
                .{ .read = true },
            );
            defer file.close();
            break :blk try readLines(
                file.reader(),
                &arena.allocator,
            );
        };
        log.info("Rendering {s}/{s}", .{ gmi_out_path, page.filename });
        const doc = try parseDocument(
            lines,
            page.filename,
            &arena.allocator,
        );
        inline for (@typeInfo(Ext).Enum.fields) |fld| {
            const out_dir = try std.fs.cwd().openDir(fld.name, .{});
            const out_path = switch (@field(Ext, fld.name)) {
                .gmi => gmi_out_path,
                .html => html_out_path,
            };
            try out_dir.makePath(out_path);
            const blog_out_dir = try out_dir.openDir(out_path, .{});
            const out_filename = try std.mem.concat(
                &arena.allocator,
                u8,
                &[_][]const u8{ page.filename, ".", fld.name },
            );
            defer arena.allocator.free(out_filename);
            const out_file = try blog_out_dir.createFile(out_filename, .{});
            defer out_file.close();
            const writer = out_file.writer();
            try formatDoc(
                doc,
                writer,
                @field(Ext, fld.name),
                back_text,
                include_dates,
            );
        }
    }
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
    filename: []const u8,
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
    filename: []const u8,
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
        .filename = filename,
    };
    return result;
}

// wow so many things can go wrong with computers
const ParseError = std.mem.Allocator.Error ||
    std.process.GetEnvVarOwnedError || std.fs.File.ReadError ||
    std.fs.File.WriteError || std.ChildProcess.SpawnError ||
    error{ProcessEndedUnexpectedly};

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
        if (try parseCommand(lines[index], allocator)) |res| {
            try blocks.appendSlice(res);
            index += 1;
        } else if (try parseBlock(lines, index, allocator)) |res| {
            if (spans.items.len > 0) {
                try blocks.append(.{ .paragraph = spans.toOwnedSlice() });
            }
            try blocks.append(res.data);
            index = res.new_pos;
        } else if (spans.items.len > 0 and lines[index].len == 0) {
            try blocks.append(.{ .paragraph = spans.toOwnedSlice() });
            index += 1;
        } else if (try parseSpans(lines[index], 0, allocator, null)) |res| {
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
    line: []const u8,
    allocator: *std.mem.Allocator,
) !?[]const Block {
    if (!std.mem.startsWith(u8, line, ": ")) return null;
    const shell = try std.process.getEnvVarOwned(allocator, "SHELL");

    var process = try std.ChildProcess.init(&[_][]const u8{shell}, allocator);
    defer process.deinit();
    process.stdin_behavior = .Pipe;
    process.stdout_behavior = .Pipe;

    try process.spawn();
    errdefer _ = process.kill() catch |err| {
        log.warn("Had trouble cleaning up process: {}", .{err});
    };

    try process.stdin.?.writer().writeAll(line[2..]);
    process.stdin.?.close();
    process.stdin = null;

    const lines = try readLines(process.stdout.?.reader(), allocator);
    switch (try process.wait()) {
        .Exited => {
            return try parseBlocks(lines, 0, allocator);
        },
        else => return error.ProcessEndedUnexpectedly,
    }
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

fn parseToc(line: []const u8) bool {
    return std.mem.eql(u8, line, "!toc");
}

fn parseHeading(line: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, line, "# ")) return line[2..];
    return null;
}

fn parseSubheading(line: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, line, "## ")) return line[2..];
    return null;
}

fn parseEnd(line: []const u8) ?bool {
    return std.mem.eql(u8, line, "!end");
}

fn parseList(
    lines: []const []const u8,
    start: usize,
    allocator: *std.mem.Allocator,
    comptime symbol: []const u8,
) std.mem.Allocator.Error!?ParseResult([]const []const Span) {
    var ll = start;
    if (!std.mem.startsWith(u8, lines[ll], symbol)) return null;
    var items = std.ArrayList([]const Span).init(allocator);
    while (ll < lines.len and
        std.mem.startsWith(u8, lines[ll], symbol)) : (ll += 1)
    {
        if (try parseSpans(lines[ll], symbol.len, allocator, null)) |result| {
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
        } else if (try parseSpans(lines[line], prefix.len, allocator, null)) |res| {
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
    allocator: *std.mem.Allocator,
    until: ?[]const u8,
) std.mem.Allocator.Error!?ParseResult([]const Span) {
    var col = start;
    var spans = std.ArrayList(Span).init(allocator);
    var text = std.ArrayList(u8).init(allocator);
    while (col < line.len) {
        if (until) |match| {
            if (std.mem.startsWith(u8, line[col..], match)) {
                break;
            }
        }
        if (try parseEmphasis(line, col, allocator)) |result| {
            try spans.append(.{ .text = text.toOwnedSlice() });
            try spans.append(.{ .emphasis = result.data });
            col = result.new_pos;
        } else if (try parseStrong(line, col, allocator)) |result| {
            try spans.append(.{ .text = text.toOwnedSlice() });
            try spans.append(.{ .strong = result.data });
            col = result.new_pos;
        } else if (try parseAnchor(line, col, allocator)) |result| {
            try spans.append(.{ .text = text.toOwnedSlice() });
            try spans.append(.{ .anchor = result.data });
            col = result.new_pos;
        } else {
            try text.append(line[col]);
            col += 1;
        }
    } else if (until != null) {
        text.deinit();
        spans.deinit();
        return null;
    }
    if (text.items.len > 0) {
        try spans.append(.{ .text = text.toOwnedSlice() });
    }
    return ok(@as([]const Span, spans.toOwnedSlice()), col);
}

fn parseEmphasis(
    line: []const u8,
    start: usize,
    allocator: *std.mem.Allocator,
) std.mem.Allocator.Error!?ParseResult([]const Span) {
    if (line[start] != '_') return null;
    const result = (try parseSpans(line, start + 1, allocator, "_")) orelse
        return null;
    return ok(result.data, result.new_pos + 1);
}

fn parseStrong(
    line: []const u8,
    start: usize,
    allocator: *std.mem.Allocator,
) std.mem.Allocator.Error!?ParseResult([]const Span) {
    if (line[start] != '*') return null;
    const result = (try parseSpans(line, start + 1, allocator, "*")) orelse
        return null;
    return ok(result.data, result.new_pos + 1);
}

fn parseAnchor(
    line: []const u8,
    start: usize,
    allocator: *std.mem.Allocator,
) std.mem.Allocator.Error!?ParseResult(Anchor) {
    if (line[start] == '[') {
        const result = (try parseSpans(line, start + 1, allocator, "](")) orelse
            return null;
        const end_index = (std.mem.indexOf(
            u8,
            line[result.new_pos + 2 ..],
            ")",
        ) orelse return null) + result.new_pos + 2;
        return ok(Anchor{
            .text = result.data,
            .url = line[result.new_pos + 2 .. end_index],
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
    back_text: ?[]const u8,
    include_dates: bool,
) !void {
    try writer.writeAll(html_preamble);
    try writer.print("<title>{0s} ~ Clarity's Blog</title>\n", .{doc.info.title});
    try writer.writeAll(
        \\</head>
        \\<body>
        \\
    );
    if (back_text) |text| {
        if (std.mem.eql(u8, doc.filename, "index")) {
            try writer.writeAll("<a href=\"..\">return home</a>");
        } else {
            try writer.print("<a href=\"./\">{s}</a>\n", .{text});
        }
    }
    try writer.writeAll("<main>\n");
    try writer.print(
        \\<header>
        \\  <h1>{s}</h1>
        \\
    , .{doc.info.title});
    if (include_dates) {
        try writer.print("Written {Month D, YYYY}", .{doc.info.created});
        if (doc.info.updated) |updated| {
            try writer.print(", updated {Month D, YYYY}", .{updated});
        }
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

fn formatBlogIndexHtml(pages: []const Page, writer: anytype) !void {
    try writer.writeAll(html_preamble ++
        \\<title>Clarity's Blog</title>
        \\</head>
        \\<a href="../">return home</a>
        \\<main>
        \\<header><h1>clarity's blog</h1></header>
        \\
    );
    for (pages) |page| {
        try writer.print(
            \\<a href="{s}.html">{YYYY/MM/DD} – {s}</a>
            \\
        , .{ page.filename, page.info.created, page.info.title });
    }
    try writer.writeAll(
        \\</main>
        \\</body>
        \\</html>
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

fn formatBlogIndexGmi(pages: []const Page, writer: anytype) !void {
    try writer.writeAll("# Clarity's Gemlog\n\n");
    for (pages) |page| {
        try writer.print("=> {s}.gmi {} - {s}\n", .{
            page.filename,
            page.info.created,
            page.info.title,
        });
    }
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
