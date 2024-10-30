local utils = require("ccc.utils")
local api = require("ccc.utils.api")
local hl_cache = require("ccc.handler.highlight")

---@class ccc.LspHandlerCacheEntry
---@field range lsp.Range
---@field color ccc.kit.LSP.Color
---@field hl_info ccc.hl_info

---@class ccc.LspHandlerBufferData
---@field cached_info table<integer, ccc.LspHandlerCacheEntry[]> Cached color info for each client
---@field active_requests table<integer, integer> Active lsp requests
---@field subscriber fun(client_id: integer, info: ccc.LspHandlerCacheEntry[]?)?

---@class ccc.LspHandler
---@field enabled boolean
---@field buffers table<integer, ccc.LspHandlerBufferData> Keys are bufnrs
local LspHandler = {
  enabled = false,
  buffers = {},
}

function LspHandler:enable()
  self.enabled = true

  -- attach on LspAttach
  vim.api.nvim_create_autocmd("LspAttach", {
    callback = function(args)
      if self.buffers[args.buf] then
        -- Already attached
        self:request_info(args.buf, args.data.client_id)
      else
        self:attach(args.buf)
      end
    end,
  })

  vim.api.nvim_create_autocmd("LspDetach", {
    callback = function(args)
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      if not client then
        return
      end

      local data = self.buffers[args.buf]
      if not data then
        return
      end

      -- Cancel any pending request
      local pending_request = data.active_requests[args.data.client_id]
      if pending_request then
        client.cancel_request(pending_request)
        data.active_requests[args.data.client_id] = nil
      end

      -- Notify the subscriber about detaching
      if data.subscriber then
        data.subscriber(args.data.client_id, nil)
      end

      data.cached_info[args.data.client_id] = nil
    end,
  })

  local opts = require("ccc.config").options
  if not opts.highlighter.update_insert then
    vim.api.nvim_create_autocmd("InsertLeave", {
      callback = function(args)
        self:update(args.buf)
      end,
    })
  end
end

function LspHandler:disable()
  self.enabled = false
  for bufnr, _ in pairs(self.buffers) do
    self:cancel_pending_requests(bufnr)
  end
  self.buffers = {}
end

---@private
---@param bufnr integer
function LspHandler:attach(bufnr)
  bufnr = utils.ensure_bufnr(bufnr)
  if not utils.bufnr_is_valid(bufnr) then
    self.buffers[bufnr] = nil
    return
  end

  if self.buffers[bufnr] then
    return
  end

  self.buffers[bufnr] = {
    cached_info = {},
    active_requests = {},
    color_info_map = {},
  }

  local opts = require("ccc.config").options
  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function()
      if not self.enabled or not self.buffers[bufnr] then
        return true
      elseif not opts.highlighter.update_insert and vim.fn.mode() == "i" then
        return
      end

      self:update(bufnr)
    end,
    on_detach = function()
      self:cancel_pending_requests(bufnr)
      self.buffers[bufnr] = nil
    end,
  })

  self:update(bufnr)
end

---@param color_infos ccc.kit.LSP.ColorInformation[]
---@return ccc.LspHandlerCacheEntry[]
local function convert_color_info(color_infos)
  local result = {}
  for _, color_info in ipairs(color_infos) do
    local range = color_info.range
    local color = color_info.color
    local hl_name = hl_cache:ensure_hl_name({ color.red, color.green, color.blue })
    table.insert(result, {
      range = range,
      color = color,
      hl_info = {
        range = {
          range.start.line,
          range.start.character,
          range["end"].line,
          range["end"].character,
        },
        hl_name = hl_name,
      },
    })
  end

  return result
end

---@private
---Asynchronously update color information
---@param bufnr integer
---@param client_id integer
function LspHandler:request_info(bufnr, client_id)
  local client = vim.lsp.get_client_by_id(client_id)
  if not client then
    return
  end

  local data = self.buffers[bufnr]
  local requests = data.active_requests
  ---@type integer?
  local request_id = requests[client_id]
  if request_id then
    -- Cancel pending request
    requests[client_id] = nil
    client.cancel_request(request_id)
  end

  local method = "textDocument/documentColor"
  local param = { textDocument = vim.lsp.util.make_text_document_params() }

  local status = false
  status, request_id = client.request(method, param, function(err, result)
    ---@cast result ccc.kit.LSP.TextDocumentDocumentColorResponse

    if not self.enabled then
      return
    end

    -- Check if this request had been cancelled
    if requests[client_id] ~= request_id then
      return
    end

    requests[client_id] = nil
    if result and err == nil then
      local cache_entry = convert_color_info(result)

      -- Cache given color info
      data.cached_info[client_id] = cache_entry

      if data.subscriber then
        data.subscriber(client_id, cache_entry)
      end
    end
  end)

  if status then
    -- Save this request id
    requests[client_id] = request_id
  end
end

---@private
---@param bufnr integer
function LspHandler:cancel_pending_requests(bufnr)
  local data = self.buffers[bufnr]
  if not data then
    return
  end

  for client_id, request_id in pairs(data.active_requests) do
    local client = vim.lsp.get_client_by_id(client_id)
    if client then
      client.cancel_request(request_id)
    end
  end

  data.active_requests = {}
end

---@private
---Asynchronously update color informations
---@param bufnr integer
function LspHandler:update(bufnr)
  local method = "textDocument/documentColor"

  ---@diagnostic disable-next-line
  local clients = (vim.lsp.get_clients or vim.lsp.get_active_clients)({ bufnr = bufnr })
  clients = vim.tbl_filter(function(client)
    if vim.fn.has("nvim-0.11") then
      return client:supports_method(method, { bufnr = bufnr })
    else
      return client.supports_method(method, { bufnr = bufnr })
    end
  end, clients)

  ---@cast clients vim.lsp.Client[]

  -- Request new info
  for _, client in ipairs(clients) do
    self:request_info(bufnr, client.id)
  end
end

---@param bufnr integer
---@return table<integer, ccc.LspHandlerCacheEntry>
function LspHandler:get_cached_info(bufnr)
  local data = self.buffers[bufnr]
  if not data then
    return {}
  end

  return data.cached_info
end

---Whether the cursor is within range
---@param range lsp.Range
---@param cursor { [1]: integer, [2]: integer  } (0,0)-index
local function is_within(range, cursor)
  local within = true
  -- lsp.Range is 0-based and the end position is exclusive.
  within = within and range.start.line <= cursor[1]
  within = within and range.start.character <= cursor[2]
  within = within and range["end"].line >= cursor[1]
  within = within and range["end"].character > cursor[2]
  return within
end

---@return integer? start_col 1-indexed
---@return integer? end_col 1-indexed, inclusive
---@return RGB?
---@return Alpha?
function LspHandler:pick()
  local bufnr = utils.ensure_bufnr(0)
  local data = self.buffers[bufnr]
  local cache_entries = data and data.cached_info or {}
  for _, color_infos in pairs(cache_entries) do
    local cursor = { api.get_cursor() }
    for _, color_info in ipairs(color_infos) do
      local range = color_info.range
      local color = color_info.color
      if is_within(range, cursor) then
        return range.start.character + 1, range["end"].character, { color.red, color.green, color.blue }, color.alpha
      end
    end
  end
end

---Subscribes to the lsp color changes
---@param bufnr integer
---@param callback fun(client_id: integer, info: ccc.LspHandlerCacheEntry[]?) info is nil if detached
function LspHandler:subscribe(bufnr, callback)
  local data = self.buffers[bufnr]
  if not data then
    self:attach(bufnr)
    data = self.buffers[bufnr]
  end

  -- Call with cached data
  for client_id, info in pairs(data.cached_info) do
    callback(client_id, info)
  end

  data.subscriber = callback
end

---@param bufnr integer
function LspHandler:unsubscribe(bufnr)
  local data = self.buffers[bufnr]
  if not data then
    return
  end

  data.subscriber = nil
end

return LspHandler
