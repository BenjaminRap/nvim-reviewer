-- Everything the review remembers between sessions, one folder per project:
--   state.json                 shared: the last review, the browser view, the reviews list
--   reviews/<review>/state.json    read marks, notes, quiz attempts, questions asked to Claude
--   reviews/<review>/explain.json  Claude's comments on each file and the overview
-- The rest of the plugin sees one table per kind (M.get, M.explain) as before;
-- saving splits it. A Neovim writes a review's files only when it changed that
-- review since it loaded them, so two Neovims on different reviews never
-- overwrite each other.
local M = {}

local stores = {} -- key: project .. "/" .. kind -> { data, timer, path, project, kind, written, shared }

local function read_json(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  if text == "" then return nil end
  local ok, data = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  if not ok then
    vim.notify("reviewer: could not read " .. path .. " (" .. tostring(data) .. "). A copy was kept as .broken.", vim.log.levels.ERROR)
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
    vim.notify("reviewer: could not save " .. path .. ": " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  f:write(vim.json.encode(data))
  f:close()
  os.rename(tmp, path)
end

-- JSON with sorted keys, to compare two versions of the same data.
local function canon(v)
  if type(v) ~= "table" then return vim.json.encode(v) end
  if vim.islist(v) and next(v) ~= nil then
    local out = {}
    for i, x in ipairs(v) do out[i] = canon(x) end
    return "[" .. table.concat(out, ",") .. "]"
  end
  local keys = vim.tbl_keys(v)
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local out = {}
  for _, k in ipairs(keys) do out[#out + 1] = vim.json.encode(tostring(k)) .. ":" .. canon(v[k]) end
  return "{" .. table.concat(out, ",") .. "}"
end
M._canon = canon

local function empty(v) return v == nil or (type(v) == "table" and next(v) == nil) end

local DEFAULTS = {
  state = function() return { version = 1, read = {}, attempts = {}, asks = {}, notes = {}, ui = {} } end,
  explain = function() return { version = 1, files = {}, steps = {} } end,
}

-- How each kind is split: the reviews present in the data, the part of one
-- review, putting a review's part back, and the shared rest.
local SPLIT = {
  state = {
    ids = function(d)
      local ids = {}
      for _, t in ipairs({ d.read, d.notes, d.reviews }) do
        for id in pairs(t or {}) do ids[id] = true end
      end
      for _, a in pairs(d.attempts or {}) do if type(a) == "table" and a.quiz then ids[a.quiz] = true end end
      for _, a in ipairs(d.asks or {}) do if a.step or a.quiz then ids[a.step or a.quiz] = true end end
      for k in pairs(type(d.ui) == "table" and type(d.ui.last) == "table" and d.ui.last or {}) do
        if k ~= "base" and k ~= "head" then ids[k] = true end
      end
      return ids
    end,
    part = function(d, id)
      local attempts, asks = {}, {}
      for qid, a in pairs(d.attempts or {}) do if type(a) == "table" and a.quiz == id then attempts[qid] = a end end
      for _, a in ipairs(d.asks or {}) do if (a.step or a.quiz) == id then asks[#asks + 1] = a end end
      local last = type(d.ui) == "table" and type(d.ui.last) == "table" and d.ui.last[id] or nil
      return { read = (d.read or {})[id], notes = (d.notes or {})[id], review = (d.reviews or {})[id],
        attempts = attempts, asks = asks, last_file = last }
    end,
    put = function(d, id, p)
      d.read[id], d.notes[id] = p.read, p.notes
      if p.review then d.reviews = d.reviews or {}; d.reviews[id] = p.review end
      for qid, a in pairs(p.attempts or {}) do d.attempts[qid] = a end
      for _, a in ipairs(p.asks or {}) do table.insert(d.asks, a) end
      if p.last_file then d.ui.last = d.ui.last or {}; d.ui.last[id] = p.last_file end
    end,
    shared = function(d)
      local last = type(d.ui) == "table" and d.ui.last
      local ui = vim.tbl_extend("force", {}, d.ui or {})
      if type(last) == "table" then ui.last = (last.base or last.head) and { base = last.base, head = last.head } or nil end
      local asks = {}
      for _, a in ipairs(d.asks or {}) do if not (a.step or a.quiz) then asks[#asks + 1] = a end end
      return { version = d.version, ui = ui, asks = asks }
    end,
  },
  explain = {
    ids = function(d)
      local ids = {}
      for id in pairs(d.steps or {}) do ids[id] = true end
      for k in pairs(d.files or {}) do
        local id = k:match("^(.-)|")
        if id then ids[id] = true end
      end
      return ids
    end,
    part = function(d, id)
      local files, prefix = {}, id .. "|"
      for k, v in pairs(d.files or {}) do
        if k:sub(1, #prefix) == prefix then files[k:sub(#prefix + 1)] = v end
      end
      return { overview = (d.steps or {})[id], files = files }
    end,
    put = function(d, id, p)
      if p.overview then d.steps[id] = p.overview end
      for path, v in pairs(p.files or {}) do d.files[id .. "|" .. path] = v end
    end,
    shared = function(d) return { version = d.version } end,
  },
}

local function review_dir(project, id) return project.data_dir .. "/reviews/" .. id:gsub("[^%w%-_.]", "_") end

-- A review's part without its empty fields, so "nothing" compares equal however it is stored.
local function clean(p)
  local out = {}
  for k, v in pairs(p) do if not empty(v) then out[k] = v end end
  return out
end

local function store(project, kind)
  local key = project.name .. "/" .. kind
  local s = stores[key]
  if not s then
    local split = SPLIT[kind]
    local path = project.data_dir .. "/" .. kind .. ".json"
    local top = read_json(path)
    local data = vim.deepcopy(top or DEFAULTS[kind]())
    for k, v in pairs(DEFAULTS[kind]()) do
      if data[k] == nil then data[k] = v end
    end
    -- an older version kept every review in the top file: moved out on the next save
    local legacy = top ~= nil and next(split.ids(top)) ~= nil
    -- what each review's file holds on disk now: a review is written only when it differs
    local written = {}
    local dir = project.data_dir .. "/reviews"
    for name, t in (vim.uv.fs_stat(dir) and vim.fs.dir(dir) or function() end) do
      if t == "directory" then
        local p = read_json(project.data_dir .. "/reviews/" .. name .. "/" .. kind .. ".json")
        if type(p) == "table" and p.id then
          local id = p.id
          p.id = nil
          split.put(data, id, p)
          written[id] = canon(clean(p))
        end
      end
    end
    s = { data = data, path = path, project = project, kind = kind, written = written,
      shared = (not legacy) and canon(split.shared(data)) or nil }
    stores[key] = s
  end
  return s
end

-- Write what this Neovim changed: the reviews it touched, and the shared part.
local function write(s)
  local split = SPLIT[s.kind]
  -- the reviews in memory, and those on disk (a review emptied here is written empty)
  local ids = split.ids(s.data)
  for id in pairs(s.written) do ids[id] = true end
  for id in pairs(ids) do
    local p = clean(split.part(s.data, id))
    local c = canon(p)
    if c ~= (s.written[id] or canon({})) then
      p.id = id
      write_json(review_dir(s.project, id) .. "/" .. s.kind .. ".json", p)
      s.written[id] = c
    end
  end
  local shared = split.shared(s.data)
  local c = canon(shared)
  if c ~= s.shared then
    -- keep the shared settings another Neovim saved, except those changed here
    local disk = read_json(s.path)
    if type(disk) == "table" and s.shared then
      local disk_shared = split.shared(vim.tbl_extend("force", DEFAULTS[s.kind](), disk))
      local before = vim.json.decode(s.shared, { luanil = { object = true, array = true } }) or {}
      for k, v in pairs(shared) do
        if canon(v) ~= canon(before[k]) then
          if type(v) == "table" and type(disk_shared[k]) == "table" and type(before[k]) == "table" and not vim.islist(v) then
            for kk, vv in pairs(v) do
              if canon(vv) ~= canon(before[k][kk]) then disk_shared[k][kk] = vv end
            end
          else
            disk_shared[k] = v
          end
        end
      end
      shared = disk_shared
      c = canon(shared)
    end
    write_json(s.path, shared)
    s.shared = c
  end
end

function M.get(project) return store(project, "state").data end
function M.explain(project) return store(project, "explain").data end

-- Debounced save; several changes in a row cost one write.
function M.save(project, kind)
  local s = store(project, kind or "state")
  if s.timer then s.timer:stop() end
  s.timer = vim.defer_fn(function()
    s.timer = nil
    write(s)
  end, 300)
end

-- Write everything now (used on exit).
function M.flush_all()
  for _, s in pairs(stores) do
    if s.timer then
      s.timer:stop()
      s.timer = nil
    end
    write(s)
  end
end

-- Forget what is loaded (tests: as after a restart).
function M._reset() stores = {} end

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
