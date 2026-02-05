-- main module file
local module = require("plugin_name.module")
local curl = require("plenary.curl")
local async = require("plenary.async")

---@class Config
---@field prompt string Prompt to send
---@field model string model to use
---@field provider string provider type
---@field credential_env_name string credential env name
-- string provider type
---@field endpoint string where to send requests
local config = {
  prompt = "You are developer vast knowledge on secure and fast code. You need to find flaws in code attached. You MUST provide response with only json array with entries with keys 1) startColumn 2) startLine 3) endColumn 4) endLine 5) message \n--- Document Start ---\n#{buffer}\n--- Document End ---",
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

local function request(prompt, opts)
  if opts.provider == "ollama" then
    return vim.json.encode({
      model = opts.model,
      prompt = prompt,
      stream = false,
    })
  end
  if opts.provider == "openai" then
    return vim.json.encode({
      model = opts.model,
      prompt = prompt,
      stream = false,
    })
  end
end

local function handle_response(opts, response)
  if opts.provider == "ollama" then
    return response.response
  end
  if opts.provider == "openai" then
    return response.choices[0].message.content
  end
end

local function validate_response(opts, response)
  -- Check if response exists
  if not response then
    vim.notify("Response is nil", vim.log.levels.WARN)
    return false
  end

  -- Check if response is a table
  if type(response) ~= "table" then
    vim.notify("Response is not a table", vim.log.levels.WARN)
    return false
  end

  -- Validate based on provider
  if opts.provider == "ollama" then
    if not response.response then
      vim.notify("Ollama response missing 'response' field", vim.log.levels.WARN)
      return false
    end
    if type(response.response) ~= "string" then
      vim.notify("Ollama response.response is not a string", vim.log.levels.WARN)
      return false
    end
  elseif opts.provider == "openai" then
    if not response.choices then
      vim.notify("OpenAI response missing 'choices' field", vim.log.levels.WARN)
      return false
    end
    if type(response.choices) ~= "table" then
      vim.notify("OpenAI response.choices is not a table", vim.log.levels.WARN)
      return false
    end
    if not response.choices[1] then
      vim.notify("OpenAI response.choices is empty", vim.log.levels.WARN)
      return false
    end
    if not response.choices[1].message then
      vim.notify("OpenAI response.choices[1] missing 'message' field", vim.log.levels.WARN)
      return false
    end
    if not response.choices[1].message.content then
      vim.notify("OpenAI response.choices[1].message missing 'content' field", vim.log.levels.WARN)
      return false
    end
    if type(response.choices[1].message.content) ~= "string" then
      vim.notify("OpenAI response.choices[1].message.content is not a string", vim.log.levels.WARN)
      return false
    end
  else
    vim.notify("Unknown provider: " .. tostring(opts.provider), vim.log.levels.WARN)
    return false
  end

  return true
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

    if opts.credential_env_name then
      vim.print(opts.credential_env_name)
      -- vim.print(os.getenv(opts.credential_env_name))
      headers = {
        ["Content-Type"] = "application/json",
        ["Authorization"] = "Bearer " ..  os.getenv(opts.credential_env_name),
      }
    end
    curl.post(opts.endpoint, {
      headers = {
        ["Content-Type"] = "application/json",
      },
      body = request(opts, prompt),
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
        if validate_response(opts, parsed) then
          local content = handle_response(opts, parsed)

          -- Check if content is wrapped in markdown code block
          local json_content = content
          local markdown_pattern = "```json%s*(.-)%s*```"
          local extracted = content:match(markdown_pattern)

          if extracted then
            json_content = extracted
          end

          -- Update progress
          if progress_handle then
            progress_handle:report({ message = "Setting diagnostics..." })
          end

          -- Try to parse the content as JSON (assuming AI returns JSON array)
          vim.print(json_content)
          local diag_ok, diagnostics_data = pcall(vim.json.decode, json_content)

          if diag_ok and type(diagnostics_data) == "table" then
            -- Set diagnostics for the original buffer
            set_diagnostics(diagnostics_data, bufnr)

            -- Finish progress with success
            if progress_handle then
              progress_handle:finish()
            end
          else
            vim.notify("Response does not contain valid diagnostics JSON", vim.log.levels.WARN)

            -- Finish progress
            if progress_handle then
              progress_handle:finish()
            end
          end
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
