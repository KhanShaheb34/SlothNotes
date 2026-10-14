# Installed Bear resource observations

Inspected read-only on 2026-10-14. No user notes, databases, preferences, or container data were accessed. Paths below refer to the installed bundle, not user content. Values and feature names are evidence from packaged resources; they do not establish which preferences are currently active.

## Installed build

`/Applications/Bear.app/Contents/Info.plist`: bundle identifier `net.shinyfrog.bear`, version **3.0.1**, build **14853**, minimum macOS **12.4**.

## Exact colors and typography

Theme JSON is in `/Applications/Bear.app/Contents/Frameworks/BearCore.framework/Versions/A/Resources/`. Unlike a screenshot estimate, the following are literal resource values.

| Role | Red Graphite.theme | Dark Graphite.theme |
|---|---|---|
| Main background | `#FFFFFF` | `#1D1E1F` |
| Secondary background / selected note | `#F3F5F7` | `#2E2F30` |
| Tertiary background / tag chip | `#E4E5E6` | `#454647` |
| Main text | `#444444` | `#DFE0E0` |
| Secondary text / dates | `#888888` | `#A2A3A4` |
| Accent / links / cursor / list markers | `#DD4C4F` | `#44A2E5` |
| Sidebar background | `#2E3235` | `#2C2D2F` |
| Sidebar text | `#D1D1D1` | `#A5A6A6` |
| Sidebar secondary background | `#474747` | `#535354` |
| Sidebar icons | `#9FA09F` | `#ABACAB` |
| Sidebar accent | `#DD4C4F` | `#2360A3` |
| Text selection | `#D3E6FB` | `#454D56` |

Both base theme files specify editor font `BearSansUI-Regular`, size **15**, line-height multiplier **1.5**; heading font `BearSansUIHeading-Regular`, modular scale **1.125**, line-height multiplier **1.3**, top padding multiplier **0.5**, bottom padding multiplier **0.3**; code font `RobotoMono-Regular`.

Those font files are packaged in `/Applications/Bear.app/Contents/Resources/`, including regular/medium/bold/italic BearSansUI variants and regular/bold/italic BearSansUIHeading variants. OpenDyslexic and RobotoMono are also bundled. These observations establish the base theme specification, not the user's active editor font or sidebar/list font. A rebuild can use installed/system fonts without copying the commercial font assets.

There are 39 `.theme` resources (including Print). `Notes.theme` inherits Red Graphite and has yellow `#FCB827` accent and pale `#E6E3E3` sidebar; `Dark Notes.theme` inherits Dark Graphite. Other packaged names include Charcoal, Dracula, Nord, Nord Light, Tokyo Night, Tokyo Night Light, Catppuccin Latte, Catppuccin Macchiato, Rosé Pine, Rosé Pine Dawn, Solarized Light/Dark, and Everforest Light/Dark. `/Applications/Bear.app/Contents/Resources/Themes & Fonts.txt` is an older sample (claims 10 themes yet lists 16), so it should not be treated as the current theme inventory.

## Interface evidence

Compiled nib names and readable strings provide structure and feature names, not final screen geometry or proof that every menu item is visible in this build.

- `/Applications/Bear.app/Contents/Resources/Base.lproj/NoteTable.storyboardc/`: Notes, Untagged, Todo, Today, Archive, Trash; sorting by Modification Date or Creation Date; Newest on Top; Preview Style; Hide Attachments; Hide Subtag Notes. Context commands include Pin To Top, Copy Link, Open In New Window, Make Read-Only, and password actions.
- `/Applications/Bear.app/Contents/Resources/Base.lproj/Sidebar.storyboardc/`: Edit Tag, Rename tag, Pin Tag, Use as Workspace, Delete Tag, Show preferences, Show Sync Panel.
- `/Applications/Bear.app/Contents/Resources/Base.lproj/QuickOpen.storyboardc/`: search placeholder `Search notes, #tags, or @sections`.
- `/Applications/Bear.app/Contents/Resources/Base.lproj/NoteEditor.storyboardc/`: Search, Toggle Statistics, Toggle History Navigation, Open In New Window, Float on Top, Archive, Sort ToDos, heading levels 1–6 and folding. Layout modes: Show Editor Only; Show Notes and Editor; Show Tags, Notes and Editor.
- `/Applications/Bear.app/Contents/Resources/Base.lproj/Preferences.storyboardc/`: General, Typography, Themes; Text Font, Headings Font, Code Font, Font Size, Line Height, Line Width, Paragraph Spacing, Paragraph Indent. Controls include Hide Markdown, automatic tag/WikiLink/emoji completion, automatically sorting completed todos, and new-note defaults.
- `/Applications/Bear.app/Contents/Resources/en.lproj/Main.strings`: New Note, Pin To Top, Duplicate, Find and Replace, Move to Trash, Restore from Trash, Show Styles bar, and statistics labels WORDS, CHARACTERS, PARAGRAPHS, READ TIME. Contains old/debug localization strings too; their presence does not prove an exposed production UI feature.

## Bundled onboarding evidence and shortcuts

The following `.bear` files in `/Applications/Bear.app/Contents/Resources/Base.lproj/` are app-supplied ZIP/textbundle onboarding assets, not user-created notes. Their internal `text.md` contents were read directly without extraction into the rebuild.

- `Get started with Bear.bear`: first line is the note title; **⌘N** creates a note; **⇧⌘Y** shows the styles bar at the bottom of the macOS editor. CommonMark styling includes bold, italic, underline, strikethrough, highlight, headings, links, lists, todos, tables. Info panel contains statistics, headings 1–6 outline, and backlinks.
- `Organize, search, and customize in Bear.bear`: inline `#tag`, multiword `#welcome notes#`, nested `#bear/welcome`; folding nested tags in sidebar; multiple tags per note. **⇧⌘F** searches notes. Search supports quoted phrases, excluded words, `@todo`, `@images`; in-note search and replace are available. Note-list header exposes preview options.
- `Work faster and easier with Bear.bear`: double-click opens a note in a separate window; `[[` starts a wiki link; tags can have custom icons (TagCons); right-click tag supports export. iCloud sync, encryption, attachment OCR/search and extra themes/export formats are described as Pro features.

## Rebuild implications (inference)

A faithful local core should use a three-column tags → note list → Markdown editor hierarchy, red accents in the light theme, nested inline tags, note search, pinned notes, archive/trash, formatting shortcuts, and a statistics/outline panel. Exact widths, row heights, current dark/light appearance, active toolbar and menu shortcut combinations beyond the three documented above require live REA/UI observation. No proprietary images or fonts were copied during this resource inspection.
