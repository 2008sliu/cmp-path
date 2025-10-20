# cmp-path Architecture Overview

## Table of Contents
- [Introduction](#introduction)
- [Architecture](#architecture)
- [Code Structure](#code-structure)
- [Completion Flow](#completion-flow)
- [Path Resolution Logic](#path-resolution-logic)
- [Key Functions Reference](#key-functions-reference)
- [Configuration & Extension Points](#configuration--extension-points)

## Introduction

`cmp-path` is an nvim-cmp source plugin that provides intelligent filesystem path completion. It integrates with nvim-cmp's completion framework to offer context-aware path suggestions based on the current buffer and working directory.

## Architecture

### Plugin Structure

```
cmp-path/
├── lua/cmp_path/init.lua        # Main source implementation
├── after/plugin/cmp_path.lua    # Plugin registration
├── README.md                     # User documentation
└── docs/                         # Internal documentation
    └── overview.md              # This file
```

### nvim-cmp Integration

The plugin implements the nvim-cmp source interface by providing:
1. **Source Registration**: Registers 'path' as a completion source
2. **Source Methods**: Implements required methods (`complete`, `resolve`, etc.)
3. **Configuration**: Supports custom options via nvim-cmp's source config

## Code Structure

### Main Components

#### 1. Source Object (`source`)
The core table that implements the nvim-cmp source interface.

#### 2. Constants
```lua
NAME_REGEX = '\\%([^/\\\\:\\*?<>\'"`\\|]\\)'  -- Valid filename characters
PATH_REGEX = vim.regex(...)                     -- Pattern to detect path context
constants.max_lines = 20                        -- Documentation preview limit
```

#### 3. Default Options
```lua
defaults = {
  trailing_slash = false,           -- Add '/' after completed directories
  label_trailing_slash = true,      -- Show '/' in completion menu
  get_cwd = function(params) ... end -- Get base directory for relative paths
}
```

## Completion Flow

### 1. Trigger Detection
```
User types → nvim-cmp checks trigger characters → '/' or '.' triggers path source
```

**Implementation**: `source.get_trigger_characters()`
- Returns: `{ '/', '.' }`
- Note: Can be overridden via source config `trigger_characters` option

### 2. Completion Request
```
nvim-cmp → source.complete(params, callback)
         → _dirname() detects path context
         → _candidates() scans filesystem
         → callback(candidates)
```

**Flow**:
1. Validate options via `_validate_option()`
2. Extract directory path via `_dirname()`
3. If no valid path detected, return empty
4. Scan directory via `_candidates()`
5. Return completion items

### 3. Item Resolution (Preview)
```
User selects item → source.resolve(item, callback)
                  → _get_documentation() reads file preview
                  → callback(item with documentation)
```

## Path Resolution Logic

### Pattern Matching (`_dirname`)

The `_dirname()` function is the core of path detection. It analyzes `cursor_before_line` to determine:
1. **Is this a path?** (via `PATH_REGEX` matching)
2. **What type of path?** (relative, absolute, home, env var)
3. **What directory to complete from?**

### Supported Path Prefixes

| Prefix | Example | Resolves To | Notes |
|--------|---------|-------------|-------|
| `@` | `@lin` → `@links/` | Current directory | Prepends `@` to first component only |
| `@` (nested) | `@links/` → `git/` | Current directory + path | Strips `@` for resolution, no prepend |
| Bare word | `docs` | Current directory | Falls back when no `/` in path |
| `./` | `./src/` | Buffer directory + path | Explicit relative path |
| `../` | `../lib/` | Buffer directory + `/../` + path | Parent directory |
| `~/` | `~/Documents/` | Home directory + path | Tilde expansion |
| `$VAR/` | `$HOME/.config/` | Environment variable value + path | Env var expansion |
| `/` | `/usr/bin/` | Absolute path from root | Filtered for URLs/comments |
| `"` or `'` | `"./file` | Buffer directory + path | Quoted paths |

### Smart Filtering

The plugin intelligently **ignores** path-like patterns in certain contexts:

**Early exits** (checked first):
- URLs with `://` (e.g., `https://example.com/`)
- HTML closing tags `</` (e.g., `</div>`)
- Math expressions (e.g., `10 / 5`)
- Slash comments `//` (in languages with C-style comments)

**Path type detection** (in order):
1. `../` → Parent directory navigation
2. `./` or quotes → Explicit relative path
3. `~/` → Home directory
4. `$VAR/` → Environment variable expansion
5. Starts with `/` → Absolute path
6. Contains `/` → Relative path from current directory
7. No `/` → Bare filename completion from current directory

### Hidden Files Detection

Files starting with `.` are only shown when the trigger character is `.`:

```lua
-- Line 46: In complete()
local include_hidden = string.sub(params.context.cursor_before_line,
                                  params.offset, params.offset) == '.'
```

## Key Functions Reference

### Public API (nvim-cmp interface)

#### `source.new()`
Factory function to create a new source instance.
- **Returns**: Source object with metatable

#### `source.get_trigger_characters()`
Defines which characters trigger path completion.
- **Returns**: `{ '/', '.' }`
- **Note**: Can be overridden by source config `trigger_characters`

#### `source.get_keyword_pattern(self, params)`
Returns regex pattern for valid filename characters.
- **Returns**: `NAME_REGEX .. '*'` = `[^/\\:*?<>'"\|]*`
- **Purpose**: Defines word boundaries for completion

#### `source.complete(self, params, callback)`
Main completion entry point called by nvim-cmp.
- **Parameters**:
  - `params`: Context (cursor position, buffer, etc.)
  - `callback`: Function to return completion items
- **Flow**: Validate options → Detect path → Scan directory → Return candidates

#### `source.resolve(self, completion_item, callback)`
Adds documentation preview when item is selected.
- **Purpose**: Shows file preview in documentation window
- **Limits**: First 20 lines, first 1KB
- **Formats**: Syntax-highlighted markdown for known filetypes

### Internal Functions

#### `source._validate_option(self, params)`
Merges user options with defaults and validates types.
- **Returns**: Complete option table
- **Validates**: `trailing_slash`, `label_trailing_slash`, `get_cwd`

#### `source._dirname(self, params, option, starts_with_at)`
**Most complex function** - detects path context and returns directory to complete from.
- **Returns**: Absolute directory path or `nil` (if not a path context)
- **Parameters**:
  - `params`: nvim-cmp completion parameters
  - `option`: User configuration options
  - `starts_with_at`: True if current word starts with `@` (used to strip @ from prefix)
- **Algorithm**:
  1. Match `PATH_REGEX` against `cursor_before_line`
  2. Extract `prefix` (up to and including '/') and `dirname` (path after prefix)
  3. If `starts_with_at` is true and prefix starts with `@`, strip it for path resolution
  4. Determine path type by checking prefix patterns
  5. Resolve to absolute directory path
  6. Return `nil` if context should be ignored (URLs, comments, etc.)

#### `source._candidates(self, dirname, include_hidden, option, should_prepend_at, callback)`
Scans directory and creates completion items.
- **Uses**: `vim.loop.fs_scandir()` for filesystem access
- **Creates**: Completion items with LSP CompletionItemKind (File/Folder)
- **Parameters**:
  - `dirname`: Directory to scan
  - `include_hidden`: Show dotfiles (true when typed `.`)
  - `option`: User configuration options
  - `should_prepend_at`: If true, prepend `@` to candidate fields (only for first component)
  - `callback`: Function to return candidates
- **Special handling**: When `should_prepend_at` is true, prepends `@` to:
  - `label` (shown in menu): `docs/` → `@docs/`
  - `filterText` (used for matching): `docs` → `@docs`
  - `insertText` (inserted text): `docs/` → `@docs/`
  - `word` (if set): `docs` → `@docs`
- **Note**: `should_prepend_at` is false for nested components (e.g., `@links/` → shows `git/`, not `@git/`)

#### `source._is_slash_comment(self)`
Checks if current filetype uses `//` or `/*` comments.
- **Purpose**: Avoid triggering on comment lines like `// some code`
- **Uses**: `vim.bo.commentstring`

#### `source._get_documentation(self, filename, count)`
Reads file content for preview documentation.
- **Parameters**:
  - `filename`: Absolute path
  - `count`: Max lines (default 20)
- **Detects**: Binary files (returns "binary file")
- **Formats**: Markdown with syntax highlighting for known filetypes

## Configuration & Extension Points

### User Configuration Options

Users can configure via nvim-cmp source config:

```lua
require('cmp').setup({
  sources = {
    {
      name = 'path',
      option = {
        trailing_slash = false,        -- Add '/' after completed directories
        label_trailing_slash = true,   -- Show '/' in menu for directories
        get_cwd = function(params)     -- Custom base directory function
          return vim.fn.getcwd()
        end
      },
      trigger_characters = { '/', '.', '@' }  -- Custom trigger chars (nvim-cmp option)
    }
  }
})
```

### nvim-cmp Source Config Overrides

The following can be set in source config to override defaults:
- `trigger_characters`: Array of trigger characters (nvim-cmp feature)
- `keyword_pattern`: Custom pattern for valid filename characters
- `keyword_length`: Minimum characters before showing completions

### Extension Points for Development

#### 1. Adding More Custom Prefixes

The `@` prefix implementation can be extended for other custom prefixes:

**In `complete()`:**
```lua
-- Detect custom prefix
local char_at_offset = string.sub(params.context.cursor_before_line, params.offset, params.offset)
local has_custom_prefix = (char_at_offset == '#')  -- or any other char
```

**In `_candidates()`:**
```lua
-- Prepend custom prefix to candidates
if has_custom_prefix then
  item.label = '#' .. item.label
  item.filterText = '#' .. item.filterText
  item.insertText = '#' .. item.insertText
end
```

#### 2. Custom Path Mappings

To implement path aliases (like VSCode's `@` → `src/`):

**Option 1**: Add to `defaults` table
```lua
defaults = {
  -- ... existing options ...
  path_mappings = {},  -- User-defined mappings
}
```

**Option 2**: Modify `_dirname()` to check mappings table
```lua
-- In _dirname(), before other prefix checks
for alias, target_dir in pairs(option.path_mappings or {}) do
  local pattern = '^' .. vim.pesc(alias) .. '/'
  if prefix:match(pattern) then
    local stripped = string.gsub(prefix, pattern, '')
    return vim.fn.resolve(target_dir .. '/' .. dirname)
  end
end
```

#### 3. Custom Trigger Logic

Override `get_trigger_characters()`:
```lua
-- In user config (overrides source method)
local cmp_path = require('cmp_path')
local original_get_triggers = cmp_path.get_trigger_characters
cmp_path.get_trigger_characters = function()
  return { '/', '.', '@', '#' }  -- Add custom triggers
end
```

Or use nvim-cmp's per-source config (recommended):
```lua
sources = {
  {
    name = 'path',
    trigger_characters = { '/', '.', '@' }
  }
}
```

#### 4. Context-Aware Path Resolution

Modify `get_cwd` option for project-specific behavior:
```lua
option = {
  get_cwd = function(params)
    -- Find project root
    local root = vim.fn.finddir('.git/..', vim.fn.expand('%:p:h') .. ';')
    if root ~= '' then
      return vim.fn.fnamemodify(root, ':p:h')
    end
    -- Fallback to buffer directory
    return vim.fn.expand(('#%d:p:h'):format(params.context.bufnr))
  end
}
```

### Future Enhancement Ideas

1. **Path Mappings**: Implement `pathMappings` option (mentioned in README but not implemented)
2. **Fuzzy Matching**: Integrate fuzzy path matching for incomplete paths
3. **Recent Files**: Add MRU (Most Recently Used) file completion
4. **Git Integration**: Prioritize files tracked by git
5. **Network Paths**: Support UNC paths (`\\server\share`)
6. **Custom Ignore Patterns**: User-defined patterns to skip (like `.gitignore`)
7. **Performance**: Cache directory listings for frequently accessed paths
8. **Smart Priority**: Boost completion rank for frequently completed paths

## Special Features

### @ Prefix Support

The forked version adds special handling for `@` prefix to enable path completion with a special prefix character.

#### How It Works

**Two-Stage Detection:**

1. **`starts_with_at`** - Does the current word start with `@`?
   - Used by `_dirname()` to strip `@` from prefix for path resolution
   - Example: `@links/` → resolves to `buf_dirname/links/` (not `buf_dirname/@links/`)

2. **`should_prepend_at`** - Should we prepend `@` to candidates?
   - Only true when completing the **first component** (no `/` after `@`)
   - Pattern check: `not current_word:match('^@[^/]*/')`
   - Ensures nested components don't get extra `@` prefix

**Complete Flow:**

1. User types `@lin`
   - Extract current word: `@lin`
   - `starts_with_at = true` (word starts with @)
   - `should_prepend_at = true` (no / after @)
   - _dirname() resolves paths normally (@ not in prefix)
   - _candidates() prepends `@` to all results
   - Shows: `@links/`, `@linux/`, etc.

2. User continues with `@links/`
   - Extract current word: `@links/`
   - `starts_with_at = true` (word starts with @)
   - `should_prepend_at = false` (has / after @)
   - _dirname() strips `@` from prefix → uses `links/`
   - Resolves to: `buf_dirname/links/`
   - _candidates() does NOT prepend `@`
   - Shows: `README.md`, `git/`, etc. (no extra @)

3. User continues with `@links/git/`
   - Extract current word: `@links/git/`
   - `starts_with_at = true`
   - `should_prepend_at = false` (has / after @)
   - Resolves to: `buf_dirname/links/git/`
   - Shows files without extra `@`

**Implementation Details:**

```lua
-- In complete() (lines 79-97)
local before_cursor = params.context.cursor_before_line
local word_start = before_cursor:match('.*[%s"\']()') or 1
local current_word = before_cursor:sub(word_start)

local starts_with_at = (string.sub(current_word, 1, 1) == '@')
local should_prepend_at = starts_with_at and not current_word:match('^@[^/]*/')

-- In _dirname() (lines 174-179)
if starts_with_at and string.sub(prefix, 1, 1) == '@' then
  prefix = string.sub(prefix, 2)  -- Strip @ for path resolution
  debug_log('stripped @ from prefix:', '"' .. prefix .. '"')
end

-- In _candidates() (lines 308-316)
if should_prepend_at then
  item.label = '@' .. item.label
  item.filterText = '@' .. item.filterText
  item.insertText = '@' .. item.insertText
  if item.word then
    item.word = '@' .. item.word
  end
end
```

**Why This Design:**

- **Separate concerns**: Path resolution vs candidate decoration
- **Natural behavior**: `@links/file.txt` behaves like `links/file.txt`
- **nvim-cmp filtering**: Works seamlessly with built-in fuzzy matching
- **Extensible**: Easy to add other prefix characters using same pattern

**Use Cases:**
- Avoid conflicts with other completion sources
- Visual distinction for path completions
- Custom keybindings for path-only completion (e.g., `@` triggers only path source)

### Bare Filename Completion

When no `/` is present in the typed text (and PATH_REGEX doesn't match):

**Behavior:**
- Type: `do`
- Falls back to: Current directory scan
- Shows: `docs/`, `dotfiles/`, etc.
- nvim-cmp filters by typed text

**Implementation:**
```lua
-- In _dirname(), when PATH_REGEX doesn't match:
if not s then
  -- Extract current word
  -- Return current directory
  return buf_dirname
end
```

This enables natural completion like shell autocomplete.

## Debugging

### Enable Debug Logging

Built-in debug logging via environment variable:

```bash
# Enable logging
DEBUG_CMP_PATH=1 nvim

# View logs
tail -f ~/tmp/cmp.log
```

**Log output includes:**
- Completion trigger events
- `@` prefix detection (`starts_with_at` and `should_prepend_at` flags)
- PATH_REGEX matching results
- Path resolution decisions (including @ stripping)
- Directory being scanned
- Candidate count and samples

**Example (first component):**
```
2025-10-20 12:00:01 | === complete() called ===
2025-10-20 12:00:01 | cursor_before_line: @lin
2025-10-20 12:00:01 | offset: 2
2025-10-20 12:00:01 | detected @ prefix (first component) - will prepend @ to candidates
2025-10-20 12:00:01 | current_word: "@lin"
2025-10-20 12:00:01 | --- _dirname() called ---
2025-10-20 12:00:01 | starts_with_at: true
2025-10-20 12:00:01 | PATH_REGEX did not match
2025-10-20 12:00:01 | treating as bare filename completion from current directory
2025-10-20 12:00:01 | completing from: /home/user/project
2025-10-20 12:00:01 | dirname: /home/user/project
2025-10-20 12:00:01 | candidates count: 1
2025-10-20 12:00:01 | candidates:
2025-10-20 12:00:01 |   [1] label="@links/", filterText="@links"
```

**Example (nested component):**
```
2025-10-20 12:00:02 | === complete() called ===
2025-10-20 12:00:02 | cursor_before_line: @links/
2025-10-20 12:00:02 | offset: 7
2025-10-20 12:00:02 | @ detected but completing nested component - will NOT prepend @
2025-10-20 12:00:02 | current_word: "@links/"
2025-10-20 12:00:02 | --- _dirname() called ---
2025-10-20 12:00:02 | starts_with_at: true
2025-10-20 12:00:02 | PATH_REGEX match position: 5
2025-10-20 12:00:02 | prefix (raw): "@links/"
2025-10-20 12:00:02 | stripped @ from prefix: "links/"
2025-10-20 12:00:02 | treating as relative path from current directory
2025-10-20 12:00:02 | completing from: /home/user/project/links
2025-10-20 12:00:02 | candidates count: 3
2025-10-20 12:00:02 | candidates:
2025-10-20 12:00:02 |   [1] label="README.md", filterText="README.md"
2025-10-20 12:00:02 |   [2] label="git/", filterText="git"
```

### Test Pattern Matching

```lua
-- Test PATH_REGEX
:lua local regex = vim.regex([[\%(\%(/[^/\\:*?<>'"` |.~]\)\|\%(/\.\.\)\)*/\ze[^/\\:*?<>'"` |]*$]])
:lua vim.print(regex:match_str('./src/'))   -- Should return position
:lua vim.print(regex:match_str('hello'))    -- Should return nil (triggers bare completion)
:lua vim.print(regex:match_str('docs/'))    -- Should return position
:lua vim.print(regex:match_str('@docs/'))   -- Should return position
```

### Common Issues

**Issue: `@lin` works but `@links/` shows `@README.md` instead of `README.md`**
- **Symptom**: Nested components get extra `@` prefix
- **Check**: Log should show `should_prepend_at = false` for `@links/`
- **Cause**: Pattern check `not current_word:match('^@[^/]*/')` is failing
- **Fix**: Verify the pattern matches your path format

**Issue: `@links/` doesn't show completions**
- **Symptom**: No candidates appear after typing `@links/`
- **Check**: Log shows what path is being scanned
- **Likely causes**:
  - Directory doesn't exist (check `completing from:` in log)
  - `@` not stripped from prefix (check `stripped @ from prefix` message)
  - Directory exists but is empty

**Issue: `@` prefix not detected**
- **Symptom**: Shows `links/` instead of `@links/`
- **Check**: Log should show `detected @ prefix (first component)`
- **Cause**: Word extraction not finding `@`
- **Debug**: Check what `current_word` is in the log

## References

- [nvim-cmp source API](https://github.com/hrsh7th/nvim-cmp/blob/main/doc/cmp.txt)
- [Vim regex patterns](https://neovim.io/doc/user/pattern.html)
- [vim.loop (libuv) filesystem API](https://github.com/luvit/luv/blob/master/docs.md#file-system-operations)
