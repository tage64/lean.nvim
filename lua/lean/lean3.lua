local find_project_root = require('lspconfig.util').root_pattern('leanpkg.toml')
local dirname = require('lspconfig.util').path.dirname

local components = require('lean.infoview.components')
local subprocess_check_output = require('lean._util').subprocess_check_output

local a = require('plenary.async')

local lean3 = {}

-- Ideally this obviously would use a TOML parser but yeah choosing to
-- do nasty things and not add the dependency for now.
local _PROJECT_MARKER = '.*lean_version.*\".*:3.*'
local _STANDARD_LIBRARY_PATHS = '.*/[^/]*lean[%-]+3.+/lib/'

--- Detect whether the current buffer is a Lean 3 file using regex matching.
function lean3.__detect_regex(filename)
  local bufnr = vim.fn.bufnr(filename)
  if bufnr == -1 then return end

  local path = vim.uri_to_fname(vim.uri_from_bufnr(bufnr))
  if path:match(_STANDARD_LIBRARY_PATHS) then return true end

  local project_root = find_project_root(path)
  if project_root then
    local result = vim.fn.readfile(project_root .. '/leanpkg.toml')
    for _, line in ipairs(result) do
      if line:match(_PROJECT_MARKER) then return true end
    end
  end

  return false
end

--- Detect whether the current buffer is a Lean 3 file using elan.
function lean3.__detect_elan(filename)
  local bufnr = vim.fn.bufnr(filename)
  if bufnr == -1 then return end

  local path = vim.uri_to_fname(vim.uri_from_bufnr(bufnr))
  local version_string = (require"lean._util".subprocess_check_output
    { command = "lean", args = {"--version"}, cwd = dirname(path) })[1]
  local _, _, version_num = version_string:find("version (%d+)%.%d+%.%d+")
  if version_num == "3" then return true end

  return false
end

--- Return the current Lean 3 search path.
---
--- Includes both the Lean 3 core libraries as well as project-specific
--- directories (i.e. equivalent to what is reported by `lean --path`).
function lean3.__current_search_paths()
  local root = vim.lsp.buf.list_workspace_folders()[1]
  local result = subprocess_check_output{command = "lean", args = {"--path"}, cwd = root }
  return vim.fn.json_decode(table.concat(result, '')).path
end

local function is_widget_element(result)
  return type(result) == 'table' and result.t;
end

local buf_request = a.wrap(vim.lsp.buf_request, 4)
function lean3.update_infoview(div, bufnr, params, widget)
  local list_first = false
  local any_string_before = false
  local after_paren = false

  local function parse_widget(result)
    if type(result) == "string" then
      result = result:gsub('^%s*(.-)%s$', '%1')

      local separator = (list_first and (any_string_before and "\n" or "") or
        ((not after_paren and #result > 0 and result ~= ")" and result ~= ",") and " " or ""))
      div:start_div({}, separator, "html-string-separator")
      div:end_div()

      div:start_div({s = result}, result, "html-string")
      div:end_div()

      list_first = false
      any_string_before = true
      after_paren = false

      if result == "(" then after_paren = true end
    elseif is_widget_element(result) then
      local tag = result.t
      local children = result.c
      local tooltip = result.tt

      if tag == "label" or tag == "select" or tag == "option" then return end

      --div:start_div({element = result}, "<" .. tag .. ">", "element")
      --div:end_div()
      div:start_div({element = result}, "", "element")
      if tag == "li" then list_first = true end

      for _, child in pairs(children) do
        parse_widget(child)
      end

      if tooltip then parse_widget(tooltip) end

      if tag == "li" then list_first = false end
      div:end_div()
      --div:start_div({element = result}, "</" .. tag .. ">", "element")
      --div:end_div()
    else
      for _, child in pairs(result.c) do
        parse_widget(child)
      end
    end
  end

  params = vim.deepcopy(params)
  if widget == true then
    local err, _, result = buf_request(bufnr, "$/lean/discoverWidget", params)
    if not err and result and result.widget and result.widget.html then parse_widget(result.widget.html) end
  --elseif type(widget) == 'table' then
  else
    local _, _, result = buf_request(bufnr, "$/lean/plainGoal", params)
    if result and type(result) == "table" then
      components.goal(div, result)
    end
  end
  components.diagnostics(div, bufnr, params.position.line)
end

function lean3.lsp_enable(opts)
  opts.handlers = vim.tbl_extend("keep", opts.handlers or {}, {
    ['textDocument/publishDiagnostics'] = require"lean.lsp".handlers.diagnostics_handler;
  })
  require'lspconfig'.lean3ls.setup(opts)
end

return lean3
