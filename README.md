# Website Generator

A single-file [Zig](https://ziglang.org) project to generate static html and [gemini](https://gemini.circumlunar.space/) pages for my website from markdown-ish syntax.

[View the documentation](https://clarity.flowers/wiki/sitegen.html)

This software is by no means stable and you shouldn't depend on it unless you're comfortable with editing the source yourself.

## Installing

You will need to [install zig](https://ziglang.org/download/).

Depends on [zig-date](https://github.com/clarityflowers/zig-date) as a submodule.

```
git clone --recurse-submodules https://github.com/clarityflowers/sitegen.git
cd sitegen
zig build
```

This will produce `zig-cache/bin/sitegen`. To install to, say, `~/bin`, you could instead run `zig-cache --prefix ~`.

## How to read the source

All of the code is inside src/main.zig. At the top of the file is a doc comment with some directions on where to find what you're looking for.
