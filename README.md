# Zide

A fast, native macOS IDE for every language — JetBrains-style workflow, opens in under a second.

    ./build.sh --run        # build + launch
    zide .                  # after Settings › Tools › Install 'zide' Command

## How "every language" works
- Syntax colouring, search, run, terminal and Git work for ~55 languages out of the box.
- Smart features (completion, errors, go to definition, usages, rename, reformat, context actions,
  hover docs, file structure, symbol search) come from each language's **language server** — the same
  ones VS Code / Zed use. Installed servers are found on your login-shell PATH; for missing ones the
  status bar and Settings › Languages offer the install command (runs in Zide's terminal).

## JetBrains shortcuts (macOS keymap)
⇧⇧ Search Everywhere · ⇧⌘O Go to File · ⌥⌘O Symbol · ⇧⌘A Find Action · ⌘E Recent Files ·
⌘B Go to Definition (or ⌘-click) · ⌥F7 Find Usages · ⇧F6 Rename · ⌥⌘L Reformat · ⌥↩ Context Actions ·
F1 Quick Docs · ⌃Space Completion · ⌘F12 File Structure · F2 Next Error · ⌘[ / ⌘] Back/Forward ·
⌘D Duplicate · ⌘⌫ Delete Line · ⌘/ Comment · ⌥⇧↑↓ Move Line · ⌥↑ Extend Selection · ⌘L Go to Line ·
⌃R Run · ⌃⇧R Run File · ⌘F2 Stop · ⌘1 Project · ⌘0 Commit · ⌘7 Structure · ⌥F12 Terminal ·
⇧⌘F Find in Files · ⇧⌘R Replace in Files · ⌘K Commit · ⇧⌘K Push · ⌘T Pull.

## Debugger
Click the gutter to set a breakpoint (or ⌘F8), then **Debug** (⌃D / bug button). Uses the Debug Adapter
Protocol: `lldb-dap` (ships with Xcode) for Swift packages, Cargo projects and single Swift/C/C++/Obj-C/Rust/Zig
files; `debugpy` for Python (`pip3 install debugpy`). F8 step over · F7 step into · ⇧F8 step out ·
⌥⌘R resume · ⌘F2 stop. Frames, lazily-expanding variables, and an evaluate console.

Also: JavaScript / TypeScript via Node's built-in inspector (TS uses --experimental-strip-types, so lines map
exactly), Go via Delve (`dlv dap` over TCP), and conditional breakpoints (right-click a breakpoint).

## Folding, inlay hints, live templates
⌘- / ⌘= collapse / expand · ⇧⌘- / ⇧⌘= all · click gutter chevrons or the ⋯ placeholder. Inlay hints (types,
parameter names) come from the language server. Type a template abbreviation (`fori`, `iferr`, `forin`, `log`,
`psvm`, `html5`…) and press Tab; Tab walks the fields. Strings complete file paths after `./`, `../` or `/`.
Font size moved to ⌃⌘= / ⌃⌘-. Help menu: searchable help, shortcuts table, templates list.

## Split editors & multiple carets
⌘\ split right (same file in both panes) · ⇧⌘\ move tab to other split · ⌃` focus other split.
⌥-click add/remove caret · ⌥-drag column selection · ⌃G next occurrence · ⌃⌘G all occurrences ·
⌥⌘↑/↓ caret above/below · Esc back to one caret.

## Also
Git change bars in the gutter and blame in the status bar · Local History (File › Local History,
snapshots on every save) · Bookmarks (F3 / ⌘F3) · Scratch files (⇧⌘N) · TODO tool window ·
Markdown preview (⇧⌘P) · trims trailing spaces on save · remembers caret position per file.

## Testing language support
    .build/release/Zide --selftest path/to/file "text-before-completion" "SymbolName"
prints a JSON report (server, diagnostics, completion, hover, definition, references, symbols).
`--debugtest <file> <line> <expr>` runs a full debug session (env ZIDE_BP_CONDITION adds a condition);
`--editortest <dir>` checks carets and splits; `--editortest2 <dir>` checks folding, templates, hints, path completion.

## Notes
- `Vendor/SwiftTerm` is SwiftTerm 1.20.0 (MIT) without the optional Metal shader, so it builds without
  Xcode's separately downloaded Metal toolchain.
- Files autosave (like JetBrains); turn off in Settings › Editor.

## Licence

MIT (see `LICENSE`). The vendored SwiftTerm in `Vendor/SwiftTerm` is MIT (its LICENSE is included).
