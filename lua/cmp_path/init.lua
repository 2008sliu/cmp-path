local cmp = require 'cmp'

local NAME_REGEX = '\\%([^/\\\\:\\*?<>\'"`\\| \\t]\\)'
local PATH_REGEX = vim.regex(([[\%(\%(/PAT*[^/\\\\:\\*?<>\'"`\\| .~]\)\|\%(/\.\.\)\)*/\zePAT*$]]):gsub('PAT', NAME_REGEX))

-- Debug logging function (disabled by default)
-- To enable: Set DEBUG_CMP_PATH=1 environment variable before starting nvim
local DEBUG_ENABLED = vim.env.DEBUG_CMP_PATH == '1'
local log_initialized = false
local function debug_log(...)
  if not DEBUG_ENABLED then
    return
  end

  local log_file = io.open(vim.fn.expand('~/tmp/cmp.log'), 'a')
  if log_file then
    -- Add session separator on first log
    if not log_initialized then
      log_file:write('\n' .. string.rep('=', 80) .. '\n')
      log_file:write('New Session: ' .. os.date('%Y-%m-%d %H:%M:%S') .. '\n')
      log_file:write(string.rep('=', 80) .. '\n')
      log_initialized = true
    end

    local timestamp = os.date('%Y-%m-%d %H:%M:%S')
    local args = {...}
    local message = table.concat(vim.tbl_map(function(v)
      if type(v) == 'table' then
        return vim.inspect(v)
      else
        return tostring(v)
      end
    end, args), ' ')
    log_file:write(timestamp .. ' | ' .. message .. '\n')
    log_file:close()
  end
end

local source = {}

local constants = {
  max_lines = 20,
}

---@class cmp_path.Option
---@field public trailing_slash boolean
---@field public label_trailing_slash boolean
---@field public get_cwd fun(): string

---@type cmp_path.Option
local defaults = {
  trailing_slash = false,
  label_trailing_slash = true,
  get_cwd = function(params)
    return vim.fn.expand(('#%d:p:h'):format(params.context.bufnr))
  end,
}

source.new = function()
  return setmetatable({}, { __index = source })
end

source.get_trigger_characters = function()
  return { '/', '.' }
end

source.get_keyword_pattern = function(self, params)
  return NAME_REGEX .. '*'
end

source.complete = function(self, params, callback)
  debug_log('\n=== complete() called ===')
  debug_log('cursor_before_line:', '"' .. params.context.cursor_before_line .. '"')
  debug_log('params.offset:', params.offset)

  local option = self:_validate_option(params)

  -- Check if there's an @ prefix in the current word
  -- Extract the full word being completed (from last whitespace/quote to cursor)
  local before_cursor = params.context.cursor_before_line
  local word_start = before_cursor:match('.*[%s"\']()') or 1
  local current_word = before_cursor:sub(word_start)
  debug_log('word_start:', word_start, 'current_word:', '"' .. current_word .. '"')

  local starts_with_at = (string.sub(current_word, 1, 1) == '@')
  -- Only prepend @ to candidates if we're completing the FIRST component (no / after @)
  local should_prepend_at = starts_with_at and not current_word:match('^@[^/]*/')
  debug_log('starts_with_at:', starts_with_at, 'should_prepend_at:', should_prepend_at)

  local dirname = self:_dirname(params, option, starts_with_at)
  debug_log('dirname result:', dirname)
  if not dirname then
    debug_log('dirname is nil, returning early')
    return callback()
  end

  local include_hidden = string.sub(params.context.cursor_before_line, params.offset, params.offset) == '.'

  self:_candidates(dirname, include_hidden, option, should_prepend_at, function(err, candidates)
    if err then
      return callback()
    end
    callback(candidates)
  end)
end

source.resolve = function(self, completion_item, callback)
  local data = completion_item.data
  if data.stat and data.stat.type == 'file' then
    local ok, documentation = pcall(function()
      return self:_get_documentation(data.path, constants.max_lines)
    end)
    if ok then
      completion_item.documentation = documentation
    end
  end
  callback(completion_item)
end

source._dirname = function(self, params, option, starts_with_at)
  debug_log('=== _dirname called ===')
  debug_log('cursor_before_line:', '"' .. params.context.cursor_before_line .. '"')
  debug_log('params.offset:', params.offset)
  debug_log('starts_with_at:', starts_with_at)

  local s = PATH_REGEX:match_str(params.context.cursor_before_line)
  debug_log('PATH_REGEX match position (s):', s)

  -- Fallback: if no PATH_REGEX match, treat current word as filename
  if not s then
    debug_log('PATH_REGEX did not match')
    -- Extract current word (for completing bare filenames like "do" -> "docs/" or "@do" -> "@docs/")
    local before_cursor = params.context.cursor_before_line
    debug_log('before_cursor:', '"' .. before_cursor .. '"')
    local word_start = before_cursor:match('.*[%s"\']()') or 1
    debug_log('word_start position:', word_start)
    local current_word = before_cursor:sub(word_start)
    debug_log('current_word:', '"' .. current_word .. '"')

    -- Try to complete if we have a non-empty word
    if current_word ~= '' then
      debug_log('treating as bare filename completion from current directory')
      local buf_dirname = option.get_cwd(params)
      if vim.api.nvim_get_mode().mode == 'c' then
        buf_dirname = vim.fn.getcwd()
      end
      debug_log('completing from:', buf_dirname)
      -- Return current directory - @ prefix will be handled in _candidates
      return buf_dirname
    end

    debug_log('no valid word to complete - returning nil')
    return nil
  end

  local dirname = string.gsub(string.sub(params.context.cursor_before_line, s + 2), '%a*$', '') -- exclude '/'
  local prefix = string.sub(params.context.cursor_before_line, 1, s + 1) -- include '/'
  debug_log('dirname:', '"' .. dirname .. '"')
  debug_log('prefix (raw):', '"' .. prefix .. '"')

  -- Strip @ from prefix if present (for path resolution)
  -- The @ may be re-added to candidates by _candidates() if completing first component
  if starts_with_at and string.sub(prefix, 1, 1) == '@' then
    prefix = string.sub(prefix, 2)
    debug_log('stripped @ from prefix:', '"' .. prefix .. '"')
  end

  -- Early exit: Ignore URLs (contains ://)
  if prefix:match('://') then
    debug_log('rejected: contains :// (URL)')
    return nil
  end

  -- Early exit: Ignore HTML closing tags
  if prefix:match('</$') then
    debug_log('rejected: HTML closing tag')
    return nil
  end

  -- Early exit: Ignore math calculation
  if prefix:match('[%d%)]%s*/$') then
    debug_log('rejected: math expression')
    return nil
  end

  -- Early exit: Ignore / comment (only slashes)
  if prefix:match('^[%s/]*$') and self:_is_slash_comment() then
    debug_log('rejected: slash comment')
    return nil
  end

  local buf_dirname = option.get_cwd(params)
  debug_log('buf_dirname:', buf_dirname)

  if vim.api.nvim_get_mode().mode == 'c' then
    buf_dirname = vim.fn.getcwd()
    debug_log('command mode - using CWD:', buf_dirname)
  end

  -- Handle specific path prefixes
  if prefix:match('%.%./$') then
    debug_log('matched ../ pattern')
    return vim.fn.resolve(buf_dirname .. '/../' .. dirname)
  end

  if prefix:match('%./$') or prefix:match('"$') or prefix:match('\'$') then
    debug_log('matched ./ or quote pattern')
    return vim.fn.resolve(buf_dirname .. '/' .. dirname)
  end

  if prefix:match('~/$') then
    debug_log('matched ~/ pattern')
    return vim.fn.resolve(vim.fn.expand('~') .. '/' .. dirname)
  end

  local env_var_name = prefix:match('%$([%a_]+)/$')
  if env_var_name then
    debug_log('matched $ENV/ pattern:', env_var_name)
    local env_var_value = vim.fn.getenv(env_var_name)
    if env_var_value ~= vim.NIL then
      return vim.fn.resolve(env_var_value .. '/' .. dirname)
    end
  end

  -- Absolute path (starts with /)
  if prefix:match('^/$') then
    debug_log('matched absolute path (starts with /)')
    return vim.fn.resolve('/' .. dirname)
  end

  -- Fallback: treat as relative path from current directory
  -- This handles: docs/, src/, lib/, etc.
  if prefix:match('/$') then
    debug_log('treating as relative path from current directory')
    return vim.fn.resolve(buf_dirname .. '/' .. prefix .. dirname)
  end

  debug_log('no pattern matched - returning nil')
  return nil
end

source._candidates = function(_, dirname, include_hidden, option, should_prepend_at, callback)
  local fs, err = vim.loop.fs_scandir(dirname)
  if err then
    return callback(err, nil)
  end

  local items = {}

  local function create_item(name, fs_type)
    if not (include_hidden or string.sub(name, 1, 1) ~= '.') then
      return
    end

    local path = dirname .. '/' .. name
    local stat = vim.loop.fs_stat(path)
    local lstat = nil
    if stat then
      fs_type = stat.type
    elseif fs_type == 'link' then
      -- Broken symlink
      lstat = vim.loop.fs_lstat(dirname)
      if not lstat then
        return
      end
    else
      return
    end

    local item = {
      label = name,
      filterText = name,
      insertText = name,
      kind = cmp.lsp.CompletionItemKind.File,
      data = {
        path = path,
        type = fs_type,
        stat = stat,
        lstat = lstat,
      },
    }
    if fs_type == 'directory' then
      item.kind = cmp.lsp.CompletionItemKind.Folder
      if option.label_trailing_slash then
        item.label = name .. '/'
      else
        item.label = name
      end
      item.insertText = name .. '/'
      if not option.trailing_slash then
        item.word = name
      end
    end

    -- Prepend @ only when completing the first path component
    if should_prepend_at then
      item.label = '@' .. item.label
      item.filterText = '@' .. item.filterText
      item.insertText = '@' .. item.insertText
      if item.word then
        item.word = '@' .. item.word
      end
    end

    table.insert(items, item)
  end

  while true do
    local name, fs_type, e = vim.loop.fs_scandir_next(fs)
    if e then
      return callback(fs_type, nil)
    end
    if not name then
      break
    end
    create_item(name, fs_type)
  end

  callback(nil, items)
end

source._is_slash_comment = function(_)
  local commentstring = vim.bo.commentstring or ''
  local no_filetype = vim.bo.filetype == ''
  local is_slash_comment = false
  is_slash_comment = is_slash_comment or commentstring:match('/%*')
  is_slash_comment = is_slash_comment or commentstring:match('//')
  return is_slash_comment and not no_filetype
end

---@return cmp_path.Option
source._validate_option = function(_, params)
  local option = vim.tbl_deep_extend('keep', params.option, defaults)
  if vim.fn.has('nvim-0.11.2') == 1 then
    vim.validate('trailing_slash', option.trailing_slash, 'boolean')
    vim.validate('label_trailing_slash', option.label_trailing_slash, 'boolean')
    vim.validate('get_cwd', option.get_cwd, 'function')
  else
    vim.validate({
      trailing_slash = { option.trailing_slash, 'boolean' },
      label_trailing_slash = { option.label_trailing_slash, 'boolean' },
      get_cwd = { option.get_cwd, 'function' },
    })
  end
  return option
end

source._get_documentation = function(_, filename, count)
  local binary = assert(io.open(filename, 'rb'))
  local first_kb = binary:read(1024)
  if first_kb:find('\0') then
    return { kind = cmp.lsp.MarkupKind.PlainText, value = 'binary file' }
  end

  local contents = {}
  for content in first_kb:gmatch("[^\r\n]+") do
    table.insert(contents, content)
    if count ~= nil and #contents >= count then
      break
    end
  end

  local filetype = vim.filetype.match({ filename = filename })
  if not filetype then
    return { kind = cmp.lsp.MarkupKind.PlainText, value = table.concat(contents, '\n') }
  end

  table.insert(contents, 1, '```' .. filetype)
  table.insert(contents, '```')
  return { kind = cmp.lsp.MarkupKind.Markdown, value = table.concat(contents, '\n') }
end

return source
