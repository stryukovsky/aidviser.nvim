-- main module file
local module = require("plugin_name.module")
local curl = require("plenary.curl")
local async = require("plenary.async")
local log = require("plenary.log").new({
  plugin = "plugin_name",
  use_console = false,
  level = "info",
})

---@class Config
---@field prompt string Prompt to send
---@field model string model to use
---@field provider string provider type
---@field credential_env_name string credential env name
-- string provider type
---@field endpoint string where to send requests
local config = {
  ollama_prompt = "You are developer vast knowledge on secure and fast code. You need to find flaws in code attached. You MUST provide response with only json array with entries with keys 1) line, ALWAYS INTEGER NUMBER 2) message, ALWAYS LATIN STRING NO QUOTES OR OTHER NON ALPHANUMERIC SYMBOLS\n--- Document Start ---\n#{buffer}\n--- Document End --- You MUST check correctness of numeration of lines in your response. You MUST consider first line after Document start marker as first line in your response. ",
  openai_prompt = "You are developer vast knowledge on secure and fast code. You need to find flaws in code attached. In this code every line has its number written AT THE VERY START of line. You MUST provide response STRICTLY in format <number of line> <text of diagnostic message>. ONE DIAGNOSTIC ON ONE LINE. ALWAYS LATIN STRING NO QUOTES OR OTHER NON ALPHANUMERIC SYMBOLS\n--- Document Start ---\n#{buffer}\n--- Document End --- You MUST check correctness of numeration of lines in your response. You MUST CHECK ONLY SEVERE STUFF, DO NOT GENERATE WAY TOO MANY WARNINGS. WRITE WARNINGS ONLY RELATED TO: 1) CONCURRENCY 2) POSSIBLE REFACTORING ISSUE 3) PERFORMANCE 4) SECURITY 5) MEMORY LEAKS. You MUST ignore LINTING, FORMATTING and other MINOR ISSUES. NEVER QUOTE CODE LINE ENTIRELY. YOUR RESPONSE MUST BE IN ONE LINE. You MUST consider first line after Document start marker as first line in your response. ",
  model = "qwen2.5-coder:14b",
  provider = "ollama",
  credential_env_name = "",
  endpoint = "http://localhost:11434/api/generate",
}

---@class MyModule

local M = {}

---@type Config
M.config = config

-- Namespace for diagnostics
local namespace = vim.api.nvim_create_namespace("plugin_name_diagnostics")

---@param args Config?
M.setup = function(args)
  M.config = vim.tbl_deep_extend("force", M.config, args or {})
end

M.hello = function()
  return module.my_first_function(M.config)
end

M.connect_ollama = function(args)
  pcall(io.popen, "ollama serve > /dev/null 2>&1 &")
end

local function set_diagnostics(diagnostics_data, bufnr)
  -- Check if buffer is still valid
  if not vim.api.nvim_buf_is_valid(bufnr) then
    vim.notify("Buffer no longer valid, cannot set diagnostics", vim.log.levels.WARN)
    return
  end

  local diagnostics = {}

  for _, entry in ipairs(diagnostics_data) do
    -- Skip entries without a message
    if not entry.message or entry.message == "" then
      goto continue
    end

    -- Convert to 0-indexed (Neovim uses 0-indexed, but most editors show 1-indexed)
    local start_line = math.max(0, (entry.line or 1) - 2)
    local start_col = 0
    local end_line = start_line
    local end_col = 0
    -- local start_line = (entry.startLine or 1) - 1
    -- local start_col = (entry.startColumn or 1) - 1
    -- local end_line = (entry.endLine or entry.startLine or 1) - 1
    -- local end_col = (entry.endColumn or entry.startColumn or 1) - 1

    -- Ensure valid range
    -- if start_line < 0 then
    --   start_line = 0
    -- end
    -- if start_col < 0 then
    --   start_col = 0
    -- end
    -- if end_line < start_line then
    --   end_line = start_line
    -- end
    -- if end_col < start_col then
    --   end_col = start_col
    -- end

    -- Prepend model name to message
    local message = string.format("[%s] %s", M.config.model, entry.message)

    table.insert(diagnostics, {
      lnum = start_line,
      col = start_col,
      end_lnum = end_line,
      end_col = end_col,
      severity = vim.diagnostic.severity.INFO,
      message = message,
      source = "plugin_name",
    })

    ::continue::
  end

  -- Set diagnostics for the buffer
  vim.diagnostic.set(namespace, bufnr, diagnostics, {})

  vim.notify(string.format("Set %d diagnostic(s) in buffer %d", #diagnostics, bufnr), vim.log.levels.INFO)
end

local function request(opts, source)
  if opts.provider == "ollama" then
    local body = table.concat(source, "\n")
    if opts.ollama_prompt:match("#{buffer}") then
      body = opts.ollama_prompt:gsub("#{buffer}", "\n\n" .. body .. "\n\n")
    end
    return vim.json.encode({
      model = opts.model,
      prompt = body,
      stream = false,
    })
  end
  if opts.provider == "openai" then
    local lines = {}
    for i, text in ipairs(source) do
      table.insert(lines, string.format("%d %s", i, text))
    end
    local body = table.concat(lines, "\n")
    if opts.openai_prompt:match("#{buffer}") then
      body = opts.openai_prompt:gsub("#{buffer}", "\n\n" .. body .. "\n\n")
    end
    log.info("openai request body")
    log.info(body)
    local msg_prompt = { role = "user", content = body }
    return vim.json.encode({
      model = opts.model,
      messages = { msg_prompt },
      stream = false,
    })
  end
  vim.notify(string.format("Request cannot be performed, unknown provider %s", opts.provider), vim.log.levels.ERROR)
end

local function handle_response(opts, response)
  if opts.provider == "ollama" then
    return response.response
  end
  if opts.provider == "openai" then
    return response.choices[1].message.content
  end
end

local function parseNumberedList(text)
  local items = {}
  for line in text:gmatch("[^\r\n]+") do
    -- Match lines starting with "number<space>..." (e.g. "1 Improve readability")
    local num, msg = line:match("^%s*(%d+)%s+(.+)$")
    if num and msg then
      table.insert(items, {
        line = tonumber(num),
        message = msg,
      })
    end
  end
  return items
end

---@param args table? Optional parameters to override config
---@param callback function? Callback function(err, response)
M.send_request = function(args, callback)
  local opts = vim.tbl_deep_extend("force", M.config, args or {})

  -- Remember the buffer this request is for
  local bufnr = vim.api.nvim_get_current_buf()

  -- Get current buffer contents
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- Try to use fidget.nvim if available
  local has_fidget, fidget = pcall(require, "fidget")
  local progress_handle = nil

  if has_fidget then
    progress_handle = fidget.progress.handle.create({
      title = "AI Analysis",
      message = string.format("Sending request to %s...", opts.model),
      lsp_client = { name = "plugin_name" },
    })
  else
    -- Fallback to vim.notify if fidget is not available
    vim.notify(string.format("Sending request to %s...", opts.model), vim.log.levels.INFO)
  end

  async.run(function()
    local headers = {
      ["Content-Type"] = "application/json",
    }

    -- if opts.credential_env_name then
    --   vim.print(opts.credential_env_name)
    --   -- vim.print(os.getenv(opts.credential_env_name))
    --   headers = {
    --     ["Content-Type"] = "application/json",
    --     ["Authorization"] = "Bearer " ..  os.getenv(opts.credential_env_name),
    --   }
    -- end
    curl.post(opts.endpoint, {
      headers = {
        ["Content-Type"] = "application/json",
      },
      body = request(opts, lines),
      timeout = 12000,
      callback = vim.schedule_wrap(function(response)
        -- Update progress
        if progress_handle then
          progress_handle:report({ message = "Processing response..." })
        end

        if response.status ~= 200 then
          local err_msg = string.format("Error: HTTP %d - %s", response.status, response.body)

          -- Finish progress with error
          if progress_handle then
            progress_handle:finish()
          end

          vim.notify(err_msg, vim.log.levels.ERROR)
          if callback then
            callback(err_msg, nil)
          end
          return
        end

        local ok, parsed = pcall(vim.json.decode, response.body)
        if not ok then
          local err_msg = "Error parsing response: " .. tostring(parsed)

          -- Finish progress with error
          if progress_handle then
            progress_handle:finish()
          end

          vim.notify(err_msg, vim.log.levels.ERROR)
          if callback then
            callback(err_msg, nil)
          end
          return
        end

        -- Extract diagnostics from response and set them
        if true then
          local content = handle_response(opts, parsed)

          -- Check if content is wrapped in markdown code block
          local parsed_content = content
          local markdown_pattern = "```json%s*(.-)%s*```"
          local extracted = content:match(markdown_pattern)

          if extracted then
            parsed_content = extracted
          end

          -- Update progress
          if progress_handle then
            progress_handle:report({ message = "Setting diagnostics..." })
          end

          log.info(parsed_content)
          local diagnostics_data = parseNumberedList(parsed_content)

          set_diagnostics(diagnostics_data, bufnr)
          -- Try to parse the content as JSON (assuming AI returns JSON array)
          -- local diag_ok, diagnostics_data = pcall(vim.json.decode, parsed_content)

          -- if diag_ok and type(diagnostics_data) == "table" then
          --   -- Set diagnostics for the original buffer
          --
          --   -- Finish progress with success
          --   if progress_handle then
          --     progress_handle:finish()
          --   end
          -- else
          --   vim.notify("Response does not contain valid diagnostics JSON", vim.log.levels.WARN)
          --   vim.notify(json_content, vim.log.levels.WARN)
          --
          --   -- Finish progress
          --   if progress_handle then
          --     progress_handle:finish()
          --   end
          -- end
        else
          -- Finish progress
          if progress_handle then
            progress_handle:finish()
          end
        end

        if callback then
          callback(nil, parsed)
        end
      end),
    })
  end, function() end)
end

---Clear diagnostics from current or specified buffer
---@param bufnr number? Buffer number (defaults to current buffer)
M.clear_diagnostics = function(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  vim.diagnostic.reset(namespace, bufnr)
  vim.notify("Diagnostics cleared", vim.log.levels.INFO)
end

return M
