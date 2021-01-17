const std = @import("std");
const log = std.log.scoped(.stranger_roads);

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var arena = std.heap.ArenaAllocator.init(&gpa.allocator);
    defer arena.deinit();

    const args = try std.process.argsAlloc(&arena.allocator);
    defer std.process.argsFree(&arena.allocator, args);
    const cwd = std.fs.cwd();

    const blog_dir = try cwd.openDir("blog", .{ .iterate = true });
    inline for (@typeInfo(Ext).Enum.fields) |fld| {
        try std.fs.cwd().makePath(fld.name);
    }

    const pages = blk: {
        const pagefile = try blog_dir.openFile("pages.txt", .{});
        defer pagefile.close();
        const pages_reader = pagefile.reader();
        var page_file_buffer = std.ArrayList(u8).init(&arena.allocator);
        var pages = std.ArrayList(PageLink).init(&arena.allocator);
        while (pages_reader.readByte() catch null) |byte| {
            if (byte == '\n' and page_file_buffer.items.len > 0) {
                const file = try blog_dir.openFile(
                    page_file_buffer.items,
                    .{ .read = true },
                );
                defer file.close();
                const title = try file.reader().readUntilDelimiterAlloc(
                    &arena.allocator,
                    '\n',
                    256,
                );
                try pages.append(PageLink{
                    .title = title,
                    .filename = page_file_buffer.toOwnedSlice(),
                });
            } else {
                try page_file_buffer.append(byte);
            }
        }
        break :blk pages.toOwnedSlice();
    };

    for (pages) |page, page_index| {
        log.info("Rendering {}", .{page.title});
        const lines = blk: {
            var lines = std.ArrayList([]const u8).init(&arena.allocator);
            const file = try blog_dir.openFile(
                page.filename,
                .{ .read = true },
            );
            defer file.close();
            var current_line = std.ArrayList(u8).init(&arena.allocator);
            const reader = file.reader();
            while (reader.readByte()) |byte| {
                if (byte == '\n') {
                    try lines.append(current_line.toOwnedSlice());
                    current_line = std.ArrayList(u8).init(&arena.allocator);
                } else {
                    try current_line.append(byte);
                }
            } else |err| switch (err) {
                error.EndOfStream => {
                    try lines.append(current_line.toOwnedSlice());
                },
                else => |other_err| return other_err,
            }
            break :blk lines.toOwnedSlice();
        };
        const doc = try parseDocument(
            lines,
            &arena.allocator,
        );
        inline for (@typeInfo(Ext).Enum.fields) |fld| {
            const out_dir = try cwd.openDir(fld.name, .{});
            const out_filename = try std.mem.concat(
                &arena.allocator,
                u8,
                &[_][]const u8{ page.filename, ".", fld.name },
            );
            defer arena.allocator.free(out_filename);
            const file = try out_dir.createFile(out_filename, .{});
            defer file.close();
            const writer = file.writer();
            const prev_page = if (page_index == 0) null else pages[page_index - 1];
            const next_page = if (page_index == pages.len - 1)
                null
            else
                pages[page_index + 1];
            try formatDoc(
                doc,
                writer,
                pages,
                prev_page,
                next_page,
                @field(Ext, fld.name),
            );
        }
    }
}

// ---- MODELS ----

const Document = struct {
    title: []const u8, blocks: []const Block
};

const PageLink = struct {
    title: []const u8,
    filename: []const u8,
};

const Block = union(enum) {
    paragraph: []const Span,
    raw: Raw,
    toc,
    heading: []const u8,
    subheading: []const u8,
    divider,
    examples: []const []const Span,
    list: []const []const Span,
    list_em: []const []const Span,
    link: Link,
    unknown_command: []const u8,
};

const Ext = enum {
    html, gmi
};

const Raw = struct {
    ext: Ext,
    lines: []const []const u8,
};

const Link = struct {
    url: []const u8,
    text: ?[]const u8 = null,
};

const Span = union(enum) {
    text: []const u8,
    roll: Roll,
    blank,
    strong: []const Span,
    emphasis: []const Span,
    anchor: Anchor,
    br,
};

const Roll = enum {
    weak, strong, hit, miss
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
    var line: usize = 1;

    var blocks = std.ArrayList(Block).init(&errarena.allocator);
    while (try parseBlock(lines, line, allocator)) |res| {
        line = res.new_pos;
        try blocks.append(res.data);
    }
    const blocks_slice = blocks.toOwnedSlice();
    const result: Document = .{
        .title = title,
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

fn parseBlock(
    lines: []const []const u8,
    l: usize,
    allocator: *std.mem.Allocator,
) !?ParseResult(Block) {
    var line = l;
    while (line < lines.len and
        (lines[line].len == 0 or
        std.mem.eql(u8, lines[line], "!end")))
    {
        line += 1;
    }
    if (line >= lines.len) return null;

    if (parseRaw(lines, line)) |res| {
        return ok(Block{ .raw = res.data }, res.new_pos);
    } else if (try parseExamples(lines, line, allocator)) |res| {
        return ok(Block{ .examples = res.data }, res.new_pos);
    } else if (parseToc(lines[line])) {
        return ok(Block{ .toc = {} }, line + 1);
    } else if (parseHeading(lines[line])) |heading| {
        return ok(Block{ .heading = heading }, line + 1);
    } else if (parseSubheading(lines[line])) |subheading| {
        return ok(Block{ .subheading = subheading }, line + 1);
    } else if (parseLink(lines[line])) |link| {
        return ok(Block{ .link = link }, line + 1);
    } else if (parseDivider(lines[line])) {
        return ok(Block{ .divider = .{} }, line + 1);
    } else if (try parseList(lines, line, allocator, "- ")) |res| {
        return ok(Block{ .list = res.data }, res.new_pos);
    } else if (try parseList(lines, line, allocator, "~ ")) |res| {
        return ok(Block{ .list_em = res.data }, res.new_pos);
    } else if (try parseParagraph(lines, line, allocator)) |res| {
        return ok(Block{ .paragraph = res.data }, res.new_pos);
    } else {
        return ok(Block{ .unknown_command = lines[line] }, line + 1);
    }
}

fn parseToc(line: []const u8) bool {
    return std.mem.eql(u8, line, "!toc");
}

fn parseRaw(lines: []const []const u8, ll: usize) ?ParseResult(Raw) {
    const ext = loop: inline for (@typeInfo(Ext).Enum.fields) |field| {
        if (std.mem.eql(u8, lines[ll], "!" ++ field.name)) {
            break :loop @field(Ext, field.name);
        }
    } else return null;

    var end: usize = ll + 1;
    while (end < lines.len) : (end += 1) {
        const line = lines[end];
        if (std.mem.startsWith(u8, line, "!")) {
            break;
        }
    }

    return ok(
        Raw{
            .ext = ext,
            .lines = lines[ll + 1 .. end],
        },
        end,
    );
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

fn parseLink(line: []const u8) ?Link {
    if (std.mem.startsWith(u8, line, "=> ")) {
        return if (std.mem.indexOf(u8, line[3..], " ")) |index|
            Link{
                .url = line[3..index],
                .text = line[index + 4 ..],
            }
        else
            Link{
                .url = line[3..],
                .text = null,
            };
    }
    return null;
}

fn parseExamples(
    lines: []const []const u8,
    start: usize,
    allocator: *std.mem.Allocator,
) !?ParseResult([]const []const Span) {
    if (!std.mem.startsWith(u8, lines[start], "!examples")) return null;
    var line = start + 1;
    var paragraphs = std.ArrayList([]const Span).init(allocator);
    while (try parseParagraph(lines, line, allocator)) |res| {
        line = res.new_pos;
        try paragraphs.append(res.data);
    }
    return ok(@as([]const []const Span, paragraphs.toOwnedSlice()), line);
}

fn parseParagraph(
    lines: []const []const u8,
    l: usize,
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
            std.mem.startsWith(u8, line, "- "))
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
        } else if (parseRoll(line, col)) |result| {
            try spans.append(.{ .text = text.toOwnedSlice() });
            try spans.append(.{ .roll = result.data });
            col = result.new_pos;
        } else if (parseBlank(line, col)) |result| {
            try spans.append(.{ .text = text.toOwnedSlice() });
            try spans.append(.{ .blank = {} });
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

fn parseRoll(
    line: []const u8,
    start: usize,
) ?ParseResult(Roll) {
    if (line[start] != '@') return null;
    inline for (@typeInfo(Roll).Enum.fields) |fld| {
        if (std.mem.startsWith(u8, line[start + 1 ..], fld.name)) {
            return ok(@field(Roll, fld.name), start + fld.name.len + 1);
        }
    }
    return null;
}

fn parseBlank(
    line: []const u8,
    start: usize,
) ?ParseResult(void) {
    if (std.mem.startsWith(u8, line[start..], "----")) return ok({}, start + 4);
    return null;
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

fn formatDoc(
    doc: Document,
    writer: anytype,
    pages: []const PageLink,
    prev: ?PageLink,
    next: ?PageLink,
    ext: Ext,
) !void {
    switch (ext) {
        .html => return formatHtml(doc, writer, pages, prev, next),
        .gmi => return formatGmi(doc, writer, pages, prev, next),
    }
}

fn formatRoll(roll: Roll, writer: anytype) !void {
    try writer.writeAll(switch (roll) {
        .miss => "On a 3−,",
        .hit => "On a 4–6,",
        .strong => "On a 6,",
        .weak => "On a 4–5,",
    });
}

// ---- HTML FORMATTING ----

pub fn formatHtml(
    doc: Document,
    writer: anytype,
    pages: []const PageLink,
    prev: ?PageLink,
    next: ?PageLink,
) !void {
    try writer.writeAll(
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\<meta charset="UTF-8"/>
        \\<meta name="viewport" content="width=device-width, initial-scale=1.0">
        \\<link rel="stylesheet" type="text/css" href="./webfonts/fonts.css">
        \\<link rel="stylesheet" type="text/css" href="styles.css" />
        \\<link rel="icon" type="image/png" href="assets/favicon.png" />
        \\
    );
    try writer.print("<title>{0} | Stranger Roads</title>\n", .{doc.title});
    try writer.writeAll(
        \\</head>
        \\<body>
        \\
    );
    if (prev == null) {
        try writer.writeAll("<main id=\"toc\">\n");
    } else {
        try writer.writeAll("<main>\n");
    }
    if (prev != null) {
        try writer.print(
            \\<header>
            \\  <h1>{0}</h1>
            \\  <nav>
            \\
        , .{doc.title});
        for (doc.blocks) |block| switch (block) {
            .heading => |heading| {
                try writer.writeAll(
                    \\<a href="#
                );
                try formatId(heading, writer);
                try writer.print(
                    \\">{}</a>
                    \\
                , .{heading});
            },
            .divider => {
                try writer.writeAll("<hr>\n");
            },
            else => {},
        };
        try writer.writeAll(
            \\  </nav>
            \\</header>
            \\
        );
    }
    for (doc.blocks) |block| try formatBlockHtml(block, writer, pages);
    try writer.writeAll(
        \\</main>
        \\<footer><nav>
        \\
    );

    if (prev) |page|
        try writer.print(
            \\  <a href="{}.html">{}</a>
            \\
        , .{ page.filename, page.title })
    else
        try writer.writeAll("  <div></div>\n");

    try writer.writeAll(
        \\  <a href=".#Table-of-Contents">TOC</a>
        \\
    );

    if (next) |page|
        try writer.print(
            \\  <a href="{}.html">{}</a>
            \\
        , .{ page.filename, page.title })
    else
        try writer.writeAll("  <div></div>\n");

    try writer.writeAll("</nav></footer>\n");
    if (prev) |page| {
        try writer.print(
            \\<a href="{}.html" id="prev-link" aria-label="previous page"></a>
            \\
        , .{page.filename});
    }
    if (next) |page| {
        try writer.print(
            \\<a href="{}.html" id="next-link" aria-label="next page"></a>
            \\
        , .{page.filename});
    }
    if (prev != null) {
        try writer.writeAll(
            \\<a href=".#Table-of-Contents" 
            \\   id="toc-link" 
            \\   aria-label="table of contents">Table of Contents</a>
            \\
        );
    }
    try writer.writeAll(
        \\</body>
        \\</html>
        \\
    );
}

fn formatBlockHtml(
    block: Block,
    writer: anytype,
    pages: []const PageLink,
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
            try writer.print("\">{}</h2>\n", .{heading});
        },
        .subheading => |subheading| {
            try writer.writeAll("<h3 id=\"");
            try formatId(subheading, writer);
            try writer.print("\">{}</h2>\n", .{subheading});
        },
        .raw => |raw| switch (raw.ext) {
            .html => for (raw.lines) |line| try writer.print("{}\n", .{line}),
            else => {},
        },
        .link => {},
        .toc => {
            try writer.writeAll("<nav>\n");
            for (pages[1..]) |page| {
                try writer.print(
                    \\  <a href="{}.html">{}</a>
                    \\
                , .{ page.filename, page.title });
            }
            try writer.writeAll("</nav>\n");
        },
        .divider => {
            try writer.writeAll("<hr/>\n");
        },
        .list_em, .list => |list| {
            if (block == .list_em) {
                try writer.writeAll("<ul class=\"em\">\n");
            } else {
                try writer.writeAll("<ul>\n");
            }
            for (list) |item| {
                try writer.writeAll("  <li>");
                for (item) |span| try formatSpanHtml(span, writer);
                try writer.writeAll("</li>\n");
            }
            try writer.writeAll("</ul>");
        },
        .examples => |paragraphs| {
            try writer.writeAll("<div class=\"examples\">");
            for (paragraphs) |p| {
                try formatBlockHtml(Block{ .paragraph = p }, writer, pages);
            }
            try writer.writeAll("</div>");
        },
        .unknown_command => |command| {
            try writer.print("UNKNOWN COMMAND: {}\n", .{command});
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
                \\<a href="{}">
            , .{anchor.url});
            for (anchor.text) |sp| try formatSpanHtml(sp, writer);
            try writer.writeAll("</a>");
        },
        .roll => |roll| try formatRoll(roll, writer),
        .blank => try writer.writeAll(
            \\<span aria-label="blank" class="blank">____</span>
            \\
        ),
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
    pages: []const PageLink,
    prev: ?PageLink,
    next: ?PageLink,
) !void {
    try writer.print(
        \\# {}
        \\
        \\
    , .{doc.title});
    for (doc.blocks) |block| try formatBlockGmi(block, writer, pages);
    try writer.writeAll("\n");
    if (next) |page| {
        try writer.print("=> {}.gmi -> {}\n", .{ page.filename, page.title });
    }
    if (prev) |page| {
        try writer.print(
            \\=> {}.gmi <- {}
            \\=> index.gmi Table of Contents
            \\
        , .{ page.filename, page.title });
    }
}

fn formatBlockGmi(
    block: Block,
    writer: anytype,
    pages: []const PageLink,
) @TypeOf(writer).Error!void {
    switch (block) {
        .paragraph => |paragraph| {
            for (paragraph) |span| try formatSpanGmi(span, writer);
            try writer.writeAll("\n\n");
        },
        .heading => |heading| {
            try writer.print("## {}\n\n", .{heading});
        },
        .subheading => |subheading| {
            try writer.print("### {}\n\n", .{subheading});
        },
        .raw => |raw| switch (raw.ext) {
            .gmi => for (raw.lines) |line| {
                try writer.print("{}\n", .{line});
            },
            else => {},
        },
        .link => |link| {
            if (link.text) |text| {
                try writer.print("=> {} {}\n", .{ link.url, text });
            } else {
                try writer.print("=> {}\n", .{link.url});
            }
        },
        .toc => {
            for (pages[1..]) |page| {
                try writer.print(
                    "=> {}.gmi {}\n",
                    .{ page.filename, page.title },
                );
            }
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
        .list_em, .list => |list| {
            for (list) |item| {
                try writer.writeAll("* ");
                for (item) |span| try formatSpanGmi(span, writer);
                try writer.writeAll("\n");
            }
            try writer.writeAll("\n");
        },
        .examples => |paragraphs| {
            for (paragraphs) |p| {
                try formatBlockGmi(Block{ .paragraph = p }, writer, pages);
            }
        },
        .unknown_command => |command| {
            try writer.print("UNKNOWN COMMAND: {}\n", .{command});
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
        .roll => |roll| try formatRoll(roll, writer),
        .blank => try writer.writeAll("________"),
        .br => try writer.writeAll("\n"),
    }
}
