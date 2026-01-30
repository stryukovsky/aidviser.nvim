-- main module file
local module = require("plugin_name.module")
local curl = require("plenary.curl")
local async = require("plenary.async")

---@class Config
---@field prompt string Promt to send
---@field model string model to use
local config = {
  prompt = "Hello!",
  model = "qwen2.5-coder:14b",
  provider = "ollama",
  endpoint = "http://localhost:11434/api/chat",
}

---@class MyModule
local M = {}

---@type Config
M.config = config

---@param args Config?
-- you can define your setup function here. Usually configurations can be merged, accepting outside params and
-- you can also put some validation here for those.
M.setup = function(args)
  M.config = vim.tbl_deep_extend("force", M.config, args or {})
end

M.hello = function()
  -- return module.my_first_function(M.config.opt)
end
local namespace = vim.api.nvim_create_namespace("plugin_name_diagnostics")

M.connect_ollama = function(args)
  pcall(io.popen, "ollama serve > /dev/null 2>&1 &")
end

---@param diagnostics_data table Array of diagnostic entries
---@param bufnr number Buffer number to attach diagnostics to
local function set_diagnostics(diagnostics_data, bufnr)
  -- Check if buffer is still valid
  if not vim.api.nvim_buf_is_valid(bufnr) then
    vim.notify("Buffer no longer valid, cannot set diagnostics", vim.log.levels.WARN)
    return
  end

  local diagnostics = {}

  for _, entry in ipairs(diagnostics_data) do
    -- Convert to 0-indexed (Neovim uses 0-indexed, but most editors show 1-indexed)
    local start_line = (entry.startLine or 1) - 1
    local start_col = (entry.startColumn or 1) - 1
    local end_line = (entry.endLine or entry.startLine or 1) - 1
    local end_col = (entry.endColumn or entry.startColumn or 1) - 1

    -- Ensure valid range
    if start_line < 0 then
      start_line = 0
    end
    if start_col < 0 then
      start_col = 0
    end
    if end_line < start_line then
      end_line = start_line
    end
    if end_col < start_col then
      end_col = start_col
    end

    table.insert(diagnostics, {
      lnum = start_line,
      col = start_col,
      end_lnum = end_line,
      end_col = end_col,
      severity = vim.diagnostic.severity.WARN,
      message = entry.message or "No message provided",
      source = "plugin_name",
    })
  end

  -- Set diagnostics for the buffer
  vim.diagnostic.set(namespace, bufnr, diagnostics, {})

  vim.notify(string.format("Set %d diagnostic(s) in buffer %d", #diagnostics, bufnr), vim.log.levels.INFO)
end

---@param args table? Optional parameters to override config
---@param callback function? Callback function(err, response)
M.send_request = function(args, callback)
  local opts = vim.tbl_deep_extend("force", M.config, args or {})

  -- Remember the buffer this request is for
  local bufnr = vim.api.nvim_get_current_buf()

  -- Get current buffer contents
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local buffer_content = table.concat(lines, "\n")

  -- Replace #{buffer} placeholder with actual buffer contents
  -- Separated by two newlines before and after
  local prompt = opts.prompt
  if prompt:match("#{buffer}") then
    prompt = prompt:gsub("#{buffer}", "\n\n" .. buffer_content .. "\n\n")
  end

  -- Prepare the request body for Ollama chat API
  local body = vim.json.encode({
    model = opts.model,
    messages = {
      {
        role = "user",
        content = prompt,
      },
    },
    stream = false,
  })

  async.run(function()
    curl.post(opts.endpoint, {
      headers = {
        ["Content-Type"] = "application/json",
      },
      body = body,
      timeout = 120000,
      callback = vim.schedule_wrap(function(response)
        if response.status ~= 200 then
          local err_msg = string.format("Error: HTTP %d - %s", response.status, response.body)
          vim.notify(err_msg, vim.log.levels.ERROR)
          if callback then
            callback(err_msg, nil)
          end
          return
        end

        local ok, parsed = pcall(vim.json.decode, response.body)
        if not ok then
          local err_msg = "Error parsing response: " .. tostring(parsed)
          vim.notify(err_msg, vim.log.levels.ERROR)
          if callback then
            callback(err_msg, nil)
          end
          return
        end

        -- Extract diagnostics from response and set them
        if parsed.message and parsed.message.content then
          local content = parsed.message.content

          -- Try to parse the content as JSON (assuming AI returns JSON array)
          local diag_ok, diagnostics_data = pcall(vim.json.decode, content)

          if diag_ok and type(diagnostics_data) == "table" then
            -- Set diagnostics for the original buffer
            set_diagnostics(diagnostics_data, bufnr)
          else
            vim.notify("Response does not contain valid diagnostics JSON", vim.log.levels.WARN)
          end
        end

        if callback then
          callback(nil, parsed)
        end
      end),
    })
  end)
end

return M
