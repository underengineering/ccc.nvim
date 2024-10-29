local utils = require("ccc.utils")
local api = require("ccc.utils.api")
local lsp_handler = require("ccc.handler.lsp")
local picker_handler = require("ccc.handler.picker")
local hl_cache = require("ccc.handler.highlight")

---@class ccc.Highlighter
---@field picker_ns_id integer
---@field lsp_namespaces table<integer, integer> Keys are client ids
---@field attached_buffers table<integer, boolean> Keys are bufnrs.
local Highlighter = {
  picker_ns_id = vim.api.nvim_create_namespace("ccc-highlighter-picker"),
  lsp_namespaces = {},
  attached_buffers = {},
}

function Highlighter:init()
  hl_cache:init()

  local opts = require("ccc.config").options
  if not opts.highlighter.update_insert then
    vim.api.nvim_create_autocmd("InsertLeave", {
      callback = function(args)
        if not self.attached_buffers[args.buf] then
          return
        end
        self:update(args.buf, 0, -1)
      end,
    })
  end
end

---Return true if ft is valid.
---@param ft string
---@return boolean
local function ft_filter(ft)
  -- Disable in UI
  if ft == "ccc-ui" then
    return false
  end
  local opts = require("ccc.config").options
  if not opts.highlighter.auto_enable then
    return true
  elseif #opts.highlighter.filetypes > 0 then
    return vim.tbl_contains(opts.highlighter.filetypes, ft)
  else
    return not vim.tbl_contains(opts.highlighter.excludes, ft)
  end
end

---@param bufnr integer
---@param info ccc.hl_info
---@param ns_id integer
---@param opts ccc.Options
local function set_hl(bufnr, info, ns_id, opts)
  if opts.highlight_mode == "virtual" then
    local r = info.range
    local pos = opts.virtual_pos == "inline-right" and { r[3], r[4] } or { r[1], r[2] }
    local virt_pos = opts.virtual_pos == "eol" and "eol" or "inline"
    api.virtual_hl(bufnr, ns_id, pos, opts.virtual_symbol, virt_pos, info.hl_name)
  else
    api.set_hl(bufnr, ns_id, info.range, info.hl_name)
  end
end

---@private
---@param client_id integer
---@return integer
function Highlighter:get_or_create_lsp_namespace(client_id)
  local id = self.lsp_namespaces[client_id]
  if id then
    return id
  end

  local client = vim.lsp.get_client_by_id(client_id)

  ---@diagnostic disable-next-line: need-check-nil
  id = vim.api.nvim_create_namespace("ccc-highlighter-lsp." .. client.id)
  self.lsp_namespaces[client_id] = id

  return id
end

---@private
---@param bufnr integer
---@param client_id integer
---@param lsp_info ccc.LspHandlerCacheEntry[]
---@param opts ccc.Options
function Highlighter:apply_lsp_highlight(bufnr, client_id, lsp_info, opts)
  local namespace_id = self:get_or_create_lsp_namespace(client_id)
  vim.api.nvim_buf_clear_namespace(bufnr, namespace_id, 0, -1)
  for _, info in ipairs(lsp_info) do
    set_hl(bufnr, info.hl_info, namespace_id, opts)
  end
end

---@param bufnr? integer
function Highlighter:enable(bufnr)
  bufnr = utils.ensure_bufnr(bufnr)
  if self.attached_buffers[bufnr] then
    return
  end
  -- filetype filter for auto_enable
  local filetype = vim.api.nvim_get_option_value("filetype", { buf = bufnr })
  if not ft_filter(filetype) then
    return
  end

  self.attached_buffers[bufnr] = true
  self:update(bufnr, 0, -1)

  local opts = require("ccc.config").options
  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function(_, _, _, first_line, _, last_line)
      if not self.attached_buffers[bufnr] then
        return true
      elseif not opts.highlighter.update_insert and vim.fn.mode() == "i" then
        return
      end
      -- Without vim.schedule(), it does not update correctly when undo/redo
      vim.schedule(function()
        self:update(bufnr, first_line, last_line)
      end)
    end,
    on_detach = function()
      self.attached_buffers[bufnr] = nil
    end,
  })

  lsp_handler:subscribe(bufnr, function(client_id, lsp_info)
    if lsp_info == nil then
      local ns_id = self:get_or_create_lsp_namespace(client_id)
      vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
      return
    end

    self:apply_lsp_highlight(bufnr, client_id, lsp_info, opts)
  end)
end

---@param bufnr? integer
function Highlighter:disable(bufnr)
  bufnr = utils.ensure_bufnr(bufnr)
  self.attached_buffers[bufnr] = nil
  lsp_handler:unsubscribe(bufnr)
  if utils.bufnr_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, self.picker_ns_id, 0, -1)

    for _, ns_id in pairs(self.lsp_namespaces) do
      vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
    end
  end
end

---@param bufnr? integer
function Highlighter:toggle(bufnr)
  bufnr = utils.ensure_bufnr(bufnr)
  if self.attached_buffers[bufnr] then
    self:disable(bufnr)
  else
    self:enable(bufnr)
  end
end

---@param bufnr integer
---@param start_line integer
---@param end_line integer
---@param force_lsp_update boolean? Force update lsp highlights
function Highlighter:update(bufnr, start_line, end_line, force_lsp_update)
  if not utils.bufnr_is_valid(bufnr) then
    self:disable(bufnr)
    return
  end

  local opts = require("ccc.config").options
  if opts.highlighter.picker then
    local picker_info = picker_handler.info_in_range(bufnr, start_line, end_line)
    vim.api.nvim_buf_clear_namespace(bufnr, self.picker_ns_id, start_line, end_line)
    for _, info in ipairs(picker_info) do
      set_hl(bufnr, info, self.picker_ns_id, opts)
    end
  end
  if opts.highlighter.lsp and force_lsp_update then
    local cache = lsp_handler:get_cached_info(bufnr)
    for client_id, lsp_info in pairs(cache) do
      self:apply_lsp_highlight(bufnr, client_id, lsp_info, opts)
    end
  end
end

return Highlighter
