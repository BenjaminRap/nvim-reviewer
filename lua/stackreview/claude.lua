-- Runs `claude -p` (Claude Code in print mode) in the background.
-- Uses your Claude Code login and usage. Never runs tools that write.
local config = require("stackreview.config")

local M = {}

local running, queue = 0, {}
local active = {} -- job -> vim.SystemObj
M.total_cost = 0

local function extract_json(text)
  local ok, v = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  if ok then return v end
  local fenced = text:match("```json%s*(.-)```") or text:match("```%s*(.-)```")
  if fenced then
    ok, v = pcall(vim.json.decode, fenced, { luanil = { object = true, array = true } })
    if ok then return v end
  end
  local s, e = text:find("[%[{]"), nil
  for i = #text, 1, -1 do
    local c = text:sub(i, i)
    if c == "}" or c == "]" then e = i break end
  end
  if s and e and e > s then
    ok, v = pcall(vim.json.decode, text:sub(s, e), { luanil = { object = true, array = true } })
    if ok then return v end
  end
  return nil
end
M.extract_json = extract_json

local function start(job)
  running = running + 1
  local c = config.options.claude
  local cmd = { c.cmd, "-p", "--output-format", "json", "--no-session-persistence", "--tools", job.opts.tools or "" }
  if job.opts.tools and job.opts.tools ~= "" then
    vim.list_extend(cmd, { "--allowedTools", job.opts.tools })
  end
  local model = (job.opts.use and c.models and c.models[job.opts.use]) or c.model
  if model then
    vim.list_extend(cmd, { "--model", model })
    if c.fallback_model and c.fallback_model ~= model then vim.list_extend(cmd, { "--fallback-model", c.fallback_model }) end
  end
  vim.list_extend(cmd, c.extra_args or {})
  local ok, obj = pcall(vim.system, cmd, { stdin = job.prompt, cwd = job.opts.cwd, text = true, timeout = c.timeout_ms }, function(res)
    vim.schedule(function()
      running = running - 1
      active[job] = nil
      local next_job = table.remove(queue, 1)
      if next_job then start(next_job) end
      if job.cancelled then return job.cb("cancelled") end
      if res.code ~= 0 and (res.stdout or "") == "" then
        return job.cb(("claude exited with code %d%s"):format(res.code, res.stderr ~= "" and (": " .. vim.trim(res.stderr):sub(1, 300)) or ""))
      end
      local okj, out = pcall(vim.json.decode, res.stdout or "", { luanil = { object = true, array = true } })
      if not okj or type(out) ~= "table" then return job.cb("could not read Claude's reply") end
      local meta = { cost = tonumber(out.total_cost_usd) or 0, models = vim.tbl_keys(out.modelUsage or {}) }
      M.total_cost = M.total_cost + meta.cost
      if out.is_error then return job.cb(tostring(out.result or out.subtype or "Claude returned an error")) end
      local text = out.result or ""
      if job.opts.json then
        local v = extract_json(text)
        if v == nil then return job.cb("Claude's reply was not valid JSON", text, meta) end
        return job.cb(nil, v, meta)
      end
      job.cb(nil, text, meta)
    end)
  end)
  if not ok then
    running = running - 1
    vim.schedule(function() job.cb("could not start '" .. c.cmd .. "': " .. tostring(obj)) end)
  else
    active[job] = obj
  end
end

-- opts: { tools = "", cwd = dir, json = bool, tag = string, use = "overview"|"comments"|"quiz"|"final"|"ask"|"grade" }
-- cb(err, result, meta)
-- meta.cost is the call's cost in USD as reported by Claude Code.
function M.run(prompt, opts, cb)
  local job = { prompt = prompt, opts = opts or {}, cb = cb }
  if running < (config.options.claude.max_parallel or 2) then start(job) else queue[#queue + 1] = job end
  return job
end

-- Stop every call with this tag (queued ones are dropped, running ones killed).
function M.cancel(tag)
  for i = #queue, 1, -1 do
    if queue[i].opts.tag == tag then
      local job = table.remove(queue, i)
      vim.schedule(function() job.cb("cancelled") end)
    end
  end
  for job, obj in pairs(active) do
    if job.opts.tag == tag then
      job.cancelled = true
      pcall(function() obj:kill(15) end)
    end
  end
end

function M.busy() return running + #queue end

M.PROJECT_INTRO = [[You are helping a developer understand and review code from their own team project before it is merged. Answer in English, be concrete and concise, and cite locations as path:line. If something cannot be verified from the code you have, say so instead of guessing.]]

return M
