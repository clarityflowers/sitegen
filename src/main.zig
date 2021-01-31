const std = @import("std");
const log = std.log.scoped(.stranger_roads);
const Date = @import("zig-date/src/main.zig").Date;

const Dir = struct {
    src: []const u8,
    dest: []const u8,
};

pub fn main() anyerror!void {
    log.info("Hello!", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit()) log.debug("Detected memory leak.", .{});

    inline for (@typeInfo(Ext).Enum.fields) |fld| {
        try std.fs.cwd().makePath(fld.name);
    }

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
            const title = try file.reader().readUntilDelimiterAlloc(
                allocator,
                '\n',
                256,
            );
            const reader = file.reader();
            var buffer: [22]u8 = undefined;
            const len = try reader.read(&buffer);
            const writing_dates = parseWritingDates(buffer[0..len]) orelse
                return error.NoWritingDates;
            const filename = try allocator.dupe(u8, entry.name);
            try pages.append(.{
                .title = title,
                .filename = filename,
                .created = writing_dates.created,
                .updated = writing_dates.updated,
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
    for (files) |file| {
        const lines = try readLines(
            src_dir,
            file.filename,
            &arena.allocator,
        );
        log.info("Rendering {s}/{s}", .{ gmi_out_path, file.filename });
        const doc = try parseDocument(
            lines,
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
                &[_][]const u8{ file.filename, ".", fld.name },
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

/// Caller owns result
fn readLines(
    src_dir: *std.fs.Dir,
    filename: []const u8,
    allocator: *std.mem.Allocator,
) ![]const []const u8 {
    var lines = std.ArrayList([]const u8).init(allocator);
    const file = try src_dir.openFile(
        filename,
        .{ .read = true },
    );
    defer file.close();
    var current_line = std.ArrayList(u8).init(allocator);
    const reader = file.reader();
    while (reader.readByte()) |byte| {
        if (byte == '\n') {
            try lines.append(current_line.toOwnedSlice());
            current_line = std.ArrayList(u8).init(allocator);
        } else {
            try current_line.append(byte);
        }
    } else |err| switch (err) {
        error.EndOfStream => {
            try lines.append(current_line.toOwnedSlice());
        },
        else => |other_err| return other_err,
    }
    return lines.toOwnedSlice();
}

// ---- MODELS ----

const Ext = enum {
    html, gmi
};

const Document = struct {
    title: []const u8,
    blocks: []const Block,
    created: Date,
    updated: Date,
};

const WritingDates = struct {
    created: Date,
    updated: Date,
};

const Page = struct {
    title: []const u8,
    filename: []const u8,
    created: Date,
    updated: Date,
};

const Block = union(enum) {
    paragraph: []const Span,
    raw: Raw,
    heading: []const u8,
    subheading: []const u8,
    divider,
    quote: []const []const Span,
    list: []const []const Span,
    links: []const Link,
    unknown_command: []const u8,
    image: Image,
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
    allocator: *std.mem.Allocator,
) !Document {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var errarena = std.heap.ArenaAllocator.init(allocator);
    errdefer errarena.deinit();

    const title = lines[0];
    var line: usize = 2;

    const writing_dates = parseWritingDates(lines[1]) orelse
        return error.NoWritingDates;

    var blocks = std.ArrayList(Block).init(&errarena.allocator);
    var spans = std.ArrayList(Span).init(allocator);
    while (line < lines.len) {
        if (try parseBlock(lines, line, allocator)) |res| {
            if (spans.items.len > 0) {
                try blocks.append(.{ .paragraph = spans.toOwnedSlice() });
            }
            try blocks.append(res.data);
            line = res.new_pos;
        } else if (spans.items.len > 0 and lines[line].len == 0) {
            try blocks.append(.{ .paragraph = spans.toOwnedSlice() });
        } else if (std.mem.eql(u8, lines[line], "!end")) {
            line += 1;
        } else if (try parseSpans(lines[line], 0, allocator, null)) |res| {
            line += 1;
            if (spans.items.len > 0) {
                try spans.append(.{ .br = {} });
            }
            try spans.appendSlice(res.data);
        } else {
            line += 1;
        }
    }
    const blocks_slice = blocks.toOwnedSlice();
    const result: Document = .{
        .title = title,
        .created = writing_dates.created,
        .updated = writing_dates.updated,
        .blocks = blocks_slice,
    };
    return result;
}

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

fn parseWritingDates(line: []const u8) ?WritingDates {
    if (line.len < 10) return null;
    const created = Date.parse(line[0..10]) catch return null;
    const updated = if (line.len >= 21)
        Date.parse(line[11..21]) catch created
    else
        created;
    return WritingDates{
        .created = created,
        .updated = updated,
    };
}

fn parseBlock(lines: []const []const u8, line: usize, allocator: *std.mem.Allocator) !?ParseResult(Block) {
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
    } else if (parseImage(lines[line])) |image| {
        return ok(Block{ .image = image }, line + 1);
    } else if (try parseLinks(lines, line, allocator)) |res| {
        return ok(Block{ .links = res.data }, res.new_pos);
    } else if (parseDivider(lines[line])) {
        return ok(Block{ .divider = .{} }, line + 1);
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

fn parseDivider(line: []const u8) bool {
    return std.mem.eql(u8, line, "!divider");
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
    while (std.mem.startsWith(u8, lines[line], "=> ")) : (line += 1) {
        const link = if (std.mem.indexOf(u8, lines[line][3..], " ")) |index|
            Link{
                .url = lines[line][3 .. index + 3],
                .text = lines[line][index + 4 ..],
            }
        else
            Link{
                .url = lines[line][3..],
                .text = null,
            };
        try result.append(link);
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
            try spans.appendSlice(res.data);
        }
    }
    if (spans.items.len > 0) {
        try paragraphs.append(spans.toOwnedSlice());
    }
    log.debug("Line: {}", .{line});
    return ok(@as([]const []const Span, paragraphs.toOwnedSlice()), line);
}

fn parseImage(line: []const u8) ?Image {
    comptime const prefix = "[img:";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const text_end = std.mem.indexOf(u8, line, "](") orelse return null;
    const end = std.mem.indexOf(u8, line[text_end..], ")") orelse return null;
    if (std.mem.indexOf(u8, line[text_end .. text_end + end], "->")) |dest_end| {
        return Image{
            .text = line[prefix.len..text_end],
            .url = line[text_end + 2 .. text_end + dest_end],
            .destination = line[text_end + dest_end .. text_end + end],
        };
    } else {
        return Image{
            .text = line[prefix.len..text_end],
            .url = line[text_end + 2 .. text_end + end],
            .destination = null,
        };
    }
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
        .gmi => return formatGmi(doc, writer),
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
    try writer.print("<title>{0s} ~ Clarity's Blog</title>\n", .{doc.title});
    try writer.writeAll(
        \\</head>
        \\<body>
        \\
    );
    if (back_text) |text| {
        try writer.print("<a href=\"./\">{s}</a>\n", .{text});
    }
    try writer.writeAll("<main>\n");
    try writer.print(
        \\<header>
        \\  <h1>{s}</h1>
        \\
    , .{doc.title});
    if (include_dates) {
        try writer.print("Written {Month D, YYYY}", .{doc.created});
        if (!doc.updated.equals(doc.created)) {
            try writer.print(", updated {Month D, YYYY}", .{doc.updated});
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
        , .{ page.filename, page.created, page.title });
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
        .image => |image| {
            if (image.destination) |dest| {
                try writer.print(
                    \\<a class="img" href="{s}">
                , .{dest});
            }
            try writer.print(
                \\<img src="{s}" alt="{s}">
            , .{
                image.url,
                image.text,
            });
            if (image.destination != null) {
                try writer.writeAll("</a>");
            }
            try writer.writeByte('\n');
        },
        .links => |links| {
            for (links) |link| {
                const text = link.text orelse link.url;
                try writer.print("<a href=\"{s}\">{s}</a>\n", .{
                    link.url,
                    link.text,
                });
            }
        },
        .divider => {
            try writer.writeAll("<hr/>\n");
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
                try writer.print("  {s}\n", .{line});
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
) !void {
    try writer.print(
        \\# {s}
        \\
        \\
    , .{doc.title});
    for (doc.blocks) |block| try formatBlockGmi(block, writer);
    try writer.writeAll("\n");
}

fn formatBlogIndexGmi(pages: []const Page, writer: anytype) !void {
    try writer.writeAll("# Clarity's Gemlog\n\n");
    for (pages) |page| {
        try writer.print("=> {s}.gmi {} - {s}\n", .{
            page.filename,
            page.created,
            page.title,
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
        .image => {},
        .links => |links| {
            for (links) |link| {
                try writer.print("=> {s}", .{link.url});
                if (link.text) |text| {
                    try writer.print(" {s}", .{text});
                }
                try writer.writeByte('\n');
            }
            try writer.writeByte('\n');
        },
        .divider => {
            try writer.writeAll(
                \\
                \\```
                \\~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
                \\```
                \\
                \\
            );
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
