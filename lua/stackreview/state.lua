-- Everything the review remembers between sessions, one folder per project:
--   state.json   read marks, notes, quiz attempts, questions asked to Claude
--   explain.json Claude's comments on each file (kept apart because it is large)
local M = {}

local stores = {} -- key: project .. "/" .. kind -> { data, timer, path }

local function read_json(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  if text == "" then return nil end
  local ok, data = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  if not ok then
    vim.notify("stackreview: could not read " .. path .. " (" .. tostring(data) .. "). A copy was kept as .broken.", vim.log.levels.ERROR)
    os.rename(path, path .. ".broken")
    return nil
  end
  return data
end

local function write_json(path, data)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local tmp = path .. ".tmp"
  local f, err = io.open(tmp, "w")
  if not f then
    vim.notify("stackreview: could not save " .. path .. ": " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  f:write(vim.json.encode(data))
  f:close()
  os.rename(tmp, path)
end

local DEFAULTS = {
  state = function() return { version = 1, read = {}, notes = {}, attempts = {}, asks = {}, ui = {} } end,
  explain = function() return { version = 1, files = {}, steps = {} } end,
}

local function store(project, kind)
  local key = project.name .. "/" .. kind
  local s = stores[key]
  if not s then
    local path = project.data_dir .. "/" .. kind .. ".json"
    local data = read_json(path) or DEFAULTS[kind]()
    for k, v in pairs(DEFAULTS[kind]()) do
      if data[k] == nil then data[k] = v end
    end
    s = { data = data, path = path }
    stores[key] = s
  end
  return s
end

function M.get(project) return store(project, "state").data end
function M.explain(project) return store(project, "explain").data end

-- Debounced save; several changes in a row cost one write.
function M.save(project, kind)
  local s = store(project, kind or "state")
  if s.timer then s.timer:stop() end
  s.timer = vim.defer_fn(function()
    s.timer = nil
    write_json(s.path, s.data)
  end, 300)
end

-- Write everything now (used on exit).
function M.flush_all()
  for _, s in pairs(stores) do
    if s.timer then
      s.timer:stop()
      s.timer = nil
    end
    write_json(s.path, s.data)
  end
end

function M.now() return os.date("!%Y-%m-%dT%H:%M:%SZ") end

function M.uid(prefix)
  return (prefix or "") .. string.format("%x%04x", os.time(), math.random(0, 0xffff))
end

-- read marks ---------------------------------------------------------------
function M.is_read(project, step_id, path)
  local r = M.get(project).read[step_id]
  return r ~= nil and r[path] ~= nil
end

function M.set_read(project, step_id, paths, value)
  local st = M.get(project)
  st.read[step_id] = st.read[step_id] or {}
  for _, p in ipairs(paths) do
    st.read[step_id][p] = value and M.now() or nil
  end
  M.save(project)
end

return M
