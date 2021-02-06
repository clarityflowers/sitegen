# Website Generator

A single-file [Zig](https://ziglang.org) project to generate static html and [gemini](https://gemini.circumlunar.space/) pages for my website from markdown-ish syntax.

[View the documentation](https://clarity.flowers/wiki/sitegen.html)

## Installing

You will need to [install zig](https://ziglang.org/download/).

Depends on [zig-date](https://github.com/clarityflowers/zig-date) as a submodule.

```
git clone --recurse-submodules https://github.com/clarityflowers/sitegen.git
cd sitegen
zig build
```

This will produce `zig-cache/bin/sitegen`. To install to, say, `~/bin`, you could instead run `zig-cache --prefix ~`.
