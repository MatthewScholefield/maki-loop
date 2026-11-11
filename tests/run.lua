local function copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = copy(x) end
  return out
end

local function eq(a, b)
  assert(a == b, tostring(a) .. " ~= " .. tostring(b))
end

local manifest = assert(io.open("plugin.toml", "r"))
local permissions = {}
for line in manifest:lines() do
  local name, value = line:match("^([%w_]+)%s*=%s*(%a+)%s*$")
  if name then permissions[name] = value == "true" end
end
manifest:close()
local null = newproxy()

local function host(files, json)
  local h = { files = files or {}, json = json or {}, commands = {}, tools = {}, events = {}, timers = {},
    now = 0, ready = {}, notes = {}, sessions = {}, focus = "s1", created = 0, prompts = {}, calls = {}, fail = {}, detached = false }
  h.sessions.s1 = { id = "s1", cwd = "/project", model = "provider/model", mode = "build", status = "idle",
    queue = { count = 0 }, updated_at = 1, settings = { spec = "provider/model", thinking = "high", fast = false },
    tasks = { { id = "main" } }, workflow = "default", yolo = true }
  function h.spawn(fn)
    h.ready[#h.ready + 1] = coroutine.create(fn)
  end
  function h.drain()
    local n = 0
    while #h.ready > 0 do
      n = n + 1
      assert(n < 10000, "scheduler runaway")
      local co = table.remove(h.ready, 1)
      local ok, why = coroutine.resume(co)
      assert(ok, why)
      if coroutine.status(co) ~= "dead" and why ~= "blocked" then h.ready[#h.ready + 1] = co end
    end
  end
  function h.point(name)
    h.calls[name] = (h.calls[name] or 0) + 1
    if h.hook then h.hook(name, h.calls[name]) end
    coroutine.yield("yield")
    if h.fail[name] then return h.fail[name] end
  end
  function h.emit(event, data)
    h.spawn(function() h.events[event]({ event = event, data = data }) end)
  end
  function h.command(name, args)
    h.spawn(function() h.commands[name].handler({ args = args or "", fargs = {} }) end)
    h.drain()
  end
  function h.complete(summary, session, task)
    local result
    h.spawn(function()
      result = h.tools.loop_complete.handler({ summary = summary }, {
        session_id = function() return session or h.focus end,
        task_id = function() return task or "main" end,
      })
    end)
    h.drain()
    return result
  end
  function h.tick(ms)
    h.now = h.now + (ms or 0)
    local timers = h.timers
    h.timers = {}
    for _, t in ipairs(timers) do
      if not t.stopped then
        if t.at <= h.now then h.spawn(t.fn) else h.timers[#h.timers + 1] = t end
      end
    end
    h.drain()
  end
  function h.nudge()
    h.tick(15 * 60 * 1000); h.tick()
  end
  function h.finish(reason, status, session)
    session = session or h.focus
    h.sessions[session].status = status or "idle"
    h.emit("TurnEnd", { session_id = session, reason = reason or "finished", cost = 0.25 })
    h.drain()
  end
  local function ui(name)
    assert(not h.detached, "UI call in teardown: " .. name)
    return h.point(name)
  end
  local m = { NIL = null, api = {}, fs = {}, env = {}, uv = {}, session = {}, model = {}, task = {}, json = {}, async = {} }
  m.async.semaphore = function()
    local busy, waiters = false, {}
    return { acquire = function()
      if busy then waiters[#waiters + 1] = coroutine.running(); coroutine.yield("blocked") else busy = true end
      return { release = function()
        if #waiters > 0 then h.ready[#h.ready + 1] = table.remove(waiters, 1) else busy = false end
      end }
    end }
  end
  m.api.register_command = function(spec) h.commands[spec.name] = spec end
  m.api.register_tool = function(spec) h.tools[spec.name] = spec end
  m.api.create_autocmd = function(events, opts) for _, e in ipairs(events) do h.events[e] = opts.callback end end
  m.notify = function(text) assert(not h.detached, "notice in teardown"); h.notes[#h.notes + 1] = text end
  m.defer_fn = function(fn, ms)
    assert(ms == 0 or ms == 15 * 60 * 1000)
    local t = { fn = fn, at = h.now + ms, stop = function(self) self.stopped = true end }
    h.timers[#h.timers + 1] = t
    return t
  end
  m.env.state_dir = function() return "/state" end
  m.uv.cwd = function() return h.cwd or "/project" end
  m.fs.normalize = function(path)
    local parts = {}
    for part in path:gmatch("[^/]+") do
      if part == ".." then table.remove(parts) elseif part ~= "." then parts[#parts + 1] = part end
    end
    return "/" .. table.concat(parts, "/")
  end
  function h.saved(path)
    if not path then
      local cwd = m.fs.normalize(m.uv.cwd())
      local key = cwd:gsub(".", function(c) return string.format("%02x", string.byte(c)) end)
      local parts = { m.env.state_dir(), "loops" }
      for i = 1, #key, 120 do parts[#parts + 1] = key:sub(i, i + 119) end
      path = table.concat(parts, "/") .. "/state.json"
    end
    return copy(h.json[h.files[path]])
  end
  m.fs.mkdir = function(_, opts) eq(opts.parents, true); local err = h.point("mkdir"); if err then return nil, err end; return true end
  m.fs.metadata = function(path) local err = h.point("metadata"); if err then return nil, err end; return h.files[path] and { is_file = true } end
  m.fs.read = function(path) local err = h.point("fs_read"); if err then return nil, err end; return h.files[path] end
  m.fs.atomic_write = function(path, text)
    local err = h.point("write")
    if err then return nil, err end
    h.files[path] = text
    return true
  end
  m.json.encode = function(value)
    if h.fail.encode then return nil, h.fail.encode end
    local id = "json:" .. tostring(#h.json + 1)
    h.json[#h.json + 1], h.json[id] = id, copy(value)
    return id
  end
  m.json.decode = function(text, opts)
    if h.json[text] == nil then return nil, "malformed JSON" end
    local luanil = opts and opts.luanil or {}
    local function decode(value)
      if type(value) ~= "table" then return value end
      local out = {}
      for k, v in pairs(value) do
        local drop = type(k) == "number" and luanil.array or type(k) == "string" and luanil.object
        if v ~= null or not drop then out[k] = decode(v) end
      end
      return out
    end
    return decode(h.json[text])
  end
  m.session.current = function() local err = ui("current"); if err then return nil, err end; return h.focus end
  m.session.read = function(opts)
    local err = ui("read")
    if err then return nil, err end
    local s = h.sessions[opts.session]
    if not s then return nil, "not live" end
    return copy(s)
  end
  m.session.focus = function(id)
    local err = ui("focus")
    if err then return nil, err end
    if not h.sessions[id] then return nil, "not live" end
    h.focus = id
    return true
  end
  m.model.get = function() local err = ui("model"); if err then return nil, err end; return copy(h.sessions[h.focus].settings) end
  m.task.list = function() local err = ui("tasks"); if err then return nil, err end; return copy(h.sessions[h.focus].tasks) end
  m.session.new = function(opts)
    assert(permissions.session_write, "session_write permission required")
    assert(opts.prompt == nil)
    eq(opts.focus, true)
    local err = ui("new")
    if err then return nil, err end
    h.created = h.created + 1
    local s = copy(h.sessions[h.focus])
    s.id, s.status, s.queue, s.tasks = "n" .. h.created, "idle", { count = 0 }, { { id = "main" } }
    if h.new_mutate then h.new_mutate(s) end
    h.sessions[s.id] = s
    if opts.focus then h.focus = s.id end
    return s.id
  end
  m.session.set_mode = function(mode, opts)
    assert(permissions.session_settings, "session_settings permission required")
    local err = ui("mode")
    if err then return nil, err end
    h.sessions[opts.session].mode = mode
    return true
  end
  m.session.prompt = function(text, opts)
    assert(permissions.agent and permissions.session_write, "agent and session_write permissions required")
    local err = ui("prompt")
    if err then return nil, err end
    eq(h.saved().resume_parent or h.saved().owner, opts.session)
    eq(h.saved().status, "running")
    h.prompts[#h.prompts + 1] = { text = text, owner = opts.session }
    h.sessions[opts.session].status = "working"
    if h.prompt_result ~= "queued" then h.emit("TurnStart", { session_id = opts.session, text = text }) end
    return h.prompt_result or "started"
  end
  _G.maki = m
  local modules = {}
  local env = setmetatable({ maki = m }, { __index = _G })
  env.require = function(name)
    eq(name, "loop")
    if not modules[name] then
      local module = assert(loadfile("lua/" .. name .. ".lua"))
      setfenv(module, env)
      modules[name] = module() or true
    end
    return modules[name]
  end
  local entry = assert(loadfile("plugin/loop.lua"))
  setfenv(entry, env)
  entry()
  return h
end

local count = 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if not ok then error(name .. ": " .. tostring(err), 0) end
  count = count + 1
  print("ok " .. count .. " - " .. name)
end

test("package declares only the capabilities used by loop", function()
  for _, name in ipairs({ "fs_read", "fs_write", "agent", "session_write", "session_settings", "session_read" }) do
    eq(permissions[name], true)
  end
  for _, name in ipairs({ "input", "net", "run", "env" }) do
    eq(permissions[name], false)
  end
end)

test("package entrypoint registers loop commands, tool, and lifecycle hooks", function()
  local h = host()
  for _, name in ipairs({ "loop", "loop-forever", "loop-stop", "loop-status", "loop-resume" }) do
    assert(h.commands[name], "missing command: " .. name)
  end
  assert(h.tools.loop_complete)
  for _, event in ipairs({ "TurnStart", "TurnEnd", "TurnError", "SessionStatusChanged", "TaskStatusChanged", "SessionEnd", "SessionReset" }) do
    assert(h.events[event], "missing event: " .. event)
  end
  eq(#h.prompts, 0)
  eq(h.created, 0)
end)

local function started()
  local h = host()
  h.command("loop", "do the work")
  eq(#h.prompts, 1)
  return h
end

test("raw objective, current context, fresh inheritance, duplicates, cost", function()
  local h = host()
  local raw = "  work  in foo.md\nexactly  "
  eq(h.commands.loop.nargs, "+")
  eq(h.tools.loop_complete.audiences[1], "main")
  h.command("loop", raw)
  eq(h.saved().objective, raw)
  eq(h.prompts[1].owner, "s1")
  eq(h.prompts[1].text:sub(-#raw), raw)
  h.sessions.other = copy(h.sessions.s1)
  h.sessions.other.settings = { spec = "other", thinking = "off", fast = true }
  h.focus = "other"
  h.finish("finished", "working", "s1")
  h.tick()
  eq(h.created, 0)
  h.finish("finished", "idle", "s1")
  h.emit("SessionStatusChanged", { session_id = "s1", status = "idle" })
  h.drain(); h.tick()
  eq(h.created, 1); eq(#h.prompts, 2)
  eq(h.sessions.n1.settings.thinking, "high")
  eq(h.sessions.n1.settings.fast, false)
  eq(h.sessions.n1.workflow, "default"); eq(h.sessions.n1.yolo, true)
  eq(h.prompts[2].text:sub(-#raw), raw)
  h.finish("finished", "idle", "s1"); h.tick()
  eq(h.created, 1); eq(h.saved().cost, 0.25)
end)

test("forever repeats the exact prompt and cannot complete", function()
  local h = host()
  local raw = "  work  in foo.md\nexactly  "
  eq(h.commands["loop-forever"].nargs, "+")
  h.command("loop-forever", raw)
  eq(h.saved().forever, true)
  eq(h.saved().objective, raw)
  eq(h.prompts[1].owner, "s1")
  for iteration = 1, 3 do
    eq(h.prompts[iteration].text, raw)
    eq(h.complete("everything is done").is_error, true)
    eq(h.saved().status, "running"); eq(h.saved().summary, nil)
    h.finish()
    eq(h.complete("done after turn end").is_error, true)
    h.tick()
    eq(h.saved().iteration, iteration + 1)
    eq(h.prompts[iteration + 1].text, raw)
  end
  eq(h.saved().cost, 0.75)
  h.command("loop-status")
  assert(h.notes[#h.notes]:find("Loop (forever)", 1, true))
end)

test("forever stop and resume preserve the raw prompt", function()
  local h = host()
  h.command("loop-forever", "raw prompt")
  h.command("loop-stop")
  eq(h.sessions.s1.status, "working")
  h.finish(); h.tick(); eq(h.created, 0)
  h.command("loop-resume")
  eq(h.saved().forever, true); eq(h.saved().iteration, 2)
  eq(h.prompts[2].text, "raw prompt")
  eq(h.complete("done").is_error, true)
end)

test("forever reload requires resume and preserves its mode", function()
  local h = host()
  h.command("loop-forever", "raw prompt")
  local reload = host(h.files, h.json)
  reload.command("loop-status"); reload.tick()
  eq(reload.saved().status, "interrupted"); eq(#reload.prompts, 0)
  reload.command("loop-resume")
  eq(reload.saved().forever, true)
  eq(reload.prompts[1].text, "raw prompt")
  eq(reload.complete("done").is_error, true)
  reload.finish(); reload.tick()
  eq(reload.prompts[2].text, "raw prompt")
end)

for _, status in ipairs({ "working", "needs_input", "queued", "plan" }) do
  test("forever starts immediately from " .. status, function()
    local h = host()
    if status == "queued" then h.sessions.s1.queue.count = 2
    elseif status == "plan" then h.sessions.s1.mode = "plan"
    else h.sessions.s1.status = status end
    local before = copy(h.sessions.s1)
    h.command("loop-forever", "raw prompt")
    eq(h.created, 1); eq(h.prompts[1].text, "raw prompt")
    eq(h.sessions.n1.mode, "build")
    eq(h.sessions.s1.status, before.status); eq(h.sessions.s1.mode, before.mode)
    eq(h.sessions.s1.queue.count, before.queue.count)
  end)
end

for _, name in ipairs({ "loop", "loop-forever" }) do
  test(name .. " replaces the other mode and revokes pending continuation", function()
    local h = host()
    h.command(name == "loop" and "loop-forever" or "loop", "old")
    h.finish()
    h.command(name, "replacement"); h.tick()
    eq(h.saved().forever, name == "loop-forever" and true or nil)
    eq(h.saved().objective, "replacement"); eq(h.saved().iteration, 1)
    eq(h.created, 1); eq(#h.prompts, 2)
    if name == "loop-forever" then eq(h.prompts[2].text, "replacement")
    else assert(h.prompts[2].text ~= "replacement") end
    h.finish(); h.tick(); eq(h.saved().iteration, 2)
  end)

  test(name .. " rejects blank prompts without replacing active work", function()
    local h = host()
    h.command("loop-forever", "raw prompt")
    h.command(name, " \n ")
    eq(h.saved().objective, "raw prompt"); eq(h.saved().forever, true)
    eq(#h.prompts, 1)
    h.finish(); h.tick(); eq(h.prompts[2].text, "raw prompt")
  end)
end

for _, reason in ipairs({ "cancelled", "max_tokens", "max_turns", "dropped" }) do
  test("forever continues after " .. reason, function()
    local h = host()
    h.command("loop-forever", "raw prompt")
    h.finish(reason); h.tick()
    eq(h.saved().status, "running"); eq(h.created, 1)
    eq(h.prompts[2].text, "raw prompt"); eq(h.saved().cost, 0.25)
    h.finish(reason, "idle", "s1"); h.tick()
    eq(h.created, 1); eq(h.saved().cost_reports, 1)
  end)
end

for _, ending in ipairs({ "idle", "needs_input", "working", "TurnEnd" }) do
  test("forever recovers from a turn error followed by " .. ending, function()
    local h = host(); h.command("loop-forever", "raw prompt")
    h.emit("TurnError", { session_id = "s1", message = "provider failed" }); h.drain()
    if ending == "TurnEnd" then h.finish("cancelled")
    else h.sessions.s1.status = ending end
    h.tick()
    if ending == "working" then
      eq(h.created, 0); eq(h.saved().status, "rollover_pending")
      h.sessions.s1.status = "idle"
      h.emit("SessionStatusChanged", { session_id = "s1", status = "idle" }); h.drain(); h.tick()
    end
    eq(h.created, 1); eq(h.saved().status, "running")
    eq(h.prompts[2].text, "raw prompt")
  end)
end

for _, text in ipairs({ "manual follow-up", false }) do
  test("forever adopts manual turns with text " .. tostring(text), function()
    local h = host(); h.command("loop-forever", "raw prompt"); h.finish()
    h.sessions.s1.status = "working"
    h.emit("TurnStart", { session_id = "s1", text = text or nil }); h.drain(); h.tick()
    eq(h.created, 0); eq(h.saved().status, "running")
    h.finish("cancelled"); h.tick()
    eq(h.created, 1); eq(h.prompts[2].text, "raw prompt")
    eq(h.saved().cost_reports, 2)
  end)
end

for _, conflict in ipairs({ "queued", "plan", "needs_input" }) do
  test("forever continues despite " .. conflict, function()
    local h = host(); h.command("loop-forever", "raw prompt"); h.finish("cancelled")
    if conflict == "queued" then h.sessions.s1.queue.count = 2
    elseif conflict == "plan" then h.sessions.s1.mode = "plan"
    else
      h.sessions.s1.status = "needs_input"
      h.emit("SessionStatusChanged", { session_id = "s1", status = "needs_input" }); h.drain()
    end
    local before = copy(h.sessions.s1)
    h.tick()
    eq(h.created, 1); eq(h.saved().status, "running")
    eq(h.prompts[2].text, "raw prompt"); eq(h.sessions.n1.mode, "build")
    eq(h.sessions.s1.queue.count, before.queue.count)
    eq(h.sessions.s1.mode, before.mode); eq(h.sessions.s1.status, before.status)
  end)
end

for _, point in ipairs({ "read", "focus", "current", "tasks", "model", "new", "mode", "mkdir", "write" }) do
  test("forever stop revokes recovery at " .. point, function()
    local h = host(); h.command("loop-forever", "raw prompt"); h.finish("cancelled")
    local fired = false
    h.hook = function(name)
      if fired or name ~= point then return end
      fired = true
      h.spawn(function() h.commands["loop-stop"].handler({}) end)
    end
    h.tick(); h.tick(); assert(fired)
    eq(h.saved().status, "stopped"); eq(#h.prompts, 1)
  end)
end

for _, point in ipairs({ "read", "focus", "current", "tasks", "model" }) do
  test("forever manual follow-up revokes in-flight rollover at " .. point, function()
    local h = host(); h.command("loop-forever", "raw prompt"); h.finish("cancelled")
    local fired = false
    h.hook = function(name)
      if fired or name ~= point then return end
      fired = true
      h.sessions.s1.status = "working"
      h.emit("TurnStart", { session_id = "s1", text = "manual follow-up" })
    end
    h.tick(); h.tick(); assert(fired)
    eq(h.created, 0); eq(h.saved().status, "running")
    h.hook = nil
    h.finish("cancelled"); h.tick()
    eq(h.created, 1); eq(h.prompts[2].text, "raw prompt")
  end)
end

for _, action in ipairs({ "reset", "reload", "write", "wrong" }) do
  test("forever retains the " .. action .. " boundary", function()
    local h = host(); h.command("loop-forever", "raw prompt"); h.finish("cancelled")
    if action == "reset" then h.emit("SessionReset", { session_id = "s1" })
    elseif action == "reload" then h.emit("SessionEnd", { session_id = "s1", reason = "reload" })
    elseif action == "write" then h.fail.write = "disk full"
    else h.sessions.s1.cwd = "/other" end
    h.drain(); h.tick(); h.fail.write = nil
    if action == "reload" then eq(h.saved().status, "interrupted")
    else
      h.command("loop-status")
      assert(h.notes[#h.notes]:find("interrupted", 1, true))
    end
    eq(#h.prompts, 1)
  end)
end

for _, case in ipairs({ "blank", "headless", "wrong" }) do
  test("reject start " .. case, function()
    local h = host()
    local s = h.sessions.s1
    if case == "headless" then s.queue = nil end
    if case == "wrong" then s.cwd = "/elsewhere" end
    h.command("loop", case == "blank" and " \n " or "work")
    eq(#h.prompts, 0); eq(h.created, 0)
  end)
end

test("replacement commands and unrelated lifecycle", function()
  local h = started()
  h.command("loop", "different")
  eq(h.saved().objective, "different")
  eq(h.saved().owner, "n1"); eq(h.saved().iteration, 1)
  eq(#h.prompts, 2)
  eq(h.sessions.s1.status, "working")
  for _, e in ipairs({ "TurnEnd", "TurnError", "SessionReset", "SessionEnd" }) do
    h.emit(e, { session_id = "other", reason = "finished" })
  end
  h.drain(); h.tick(); eq(h.saved().status, "running"); eq(h.created, 1)
end)

for _, status in ipairs({ "running", "rollover_pending", "stopped", "interrupted", "completed", "rewound" }) do
  test("new loop replaces " .. status, function()
    local h = started()
    if status == "rollover_pending" then h.finish()
    elseif status == "stopped" then h.command("loop-stop")
    elseif status == "interrupted" then h.finish("cancelled")
    elseif status == "completed" then h.complete("done")
    elseif status == "rewound" then h.sessions.s1.status = "idle" end
    h.command("loop", "foo bar baz"); h.tick()
    eq(h.saved().objective, "foo bar baz"); eq(h.saved().status, "running")
    eq(h.saved().iteration, 1); eq(h.saved().cost, 0); eq(h.saved().summary, nil)
    eq(h.created, 1); eq(#h.prompts, 2)
    eq(h.prompts[2].text:sub(-11), "foo bar baz")
    eq(h.complete("old completion", "s1").is_error, true)
    h.finish("cancelled", "idle", "s1"); h.tick()
    eq(h.saved().status, "running"); eq(h.saved().cost, 0)
    h.finish(); h.tick()
    eq(h.created, 2); eq(#h.prompts, 3)
    eq(h.saved().objective, "foo bar baz"); eq(h.saved().iteration, 2)
  end)
end

for _, status in ipairs({ "working", "needs_input", "queued", "plan" }) do
  test("new loop starts immediately from " .. status, function()
    local h = host()
    if status == "queued" then h.sessions.s1.queue.count = 2
    elseif status == "plan" then h.sessions.s1.mode = "plan"
    else h.sessions.s1.status = status end
    h.sessions.s1.tasks[2] = { id = "sub", status = "working" }
    local before = copy(h.sessions.s1)
    h.command("loop", "new objective")
    eq(h.created, 1); eq(#h.prompts, 1)
    eq(h.saved().owner, "n1"); eq(h.saved().iteration, 1)
    eq(h.sessions.n1.mode, "build")
    eq(h.sessions.s1.status, before.status); eq(h.sessions.s1.mode, before.mode)
    eq(h.sessions.s1.queue.count, before.queue.count)
  end)
end

test("new loop replaces corrupt saved state without reading it", function()
  local h = started()
  local path = next(h.files)
  h.files[path] = "broken"
  local reload = host(h.files, h.json)
  reload.command("loop", "replacement")
  eq(#reload.prompts, 1); eq(reload.saved().objective, "replacement")
  eq(reload.calls.fs_read, nil)
end)

for _, point in ipairs({ "current", "read", "mkdir", "write", "prompt" }) do
  test("new loop supersedes initial startup at " .. point, function()
    local h = host()
    local fired = false
    h.hook = function(name)
      if fired or name ~= point then return end
      fired = true
      h.spawn(function() h.commands.loop.handler({ args = "latest objective" }) end)
    end
    h.command("loop", "old objective"); h.tick()
    assert(fired)
    eq(h.saved().objective, "latest objective"); eq(h.saved().status, "running")
    eq(h.prompts[#h.prompts].text:sub(-16), "latest objective")
    eq(#h.prompts, point == "prompt" and 2 or 1)
  end)
end

for _, point in ipairs({ "read", "focus", "current", "tasks", "model", "new", "mkdir", "write", "prompt" }) do
  test("new loop supersedes deferred handoff at " .. point, function()
    local h = started(); h.finish()
    local fired = false
    h.hook = function(name)
      if fired or name ~= point then return end
      fired = true
      h.spawn(function() h.commands.loop.handler({ args = "replacement" }) end)
    end
    h.tick(); h.tick()
    assert(fired)
    eq(h.saved().objective, "replacement"); eq(h.saved().status, "running")
    eq(h.saved().iteration, 1)
    eq(h.prompts[#h.prompts].text:sub(-11), "replacement")
    h.finish(); h.tick()
    eq(h.saved().objective, "replacement"); eq(h.saved().iteration, 2)
  end)
end

for _, point in ipairs({ "current", "read", "focus", "model", "new", "mode", "mkdir", "write", "prompt" }) do
  test("new loop supersedes replacement startup at " .. point, function()
    local h = started()
    local fired = false
    h.hook = function(name)
      if fired or name ~= point then return end
      fired = true
      h.spawn(function() h.commands.loop.handler({ args = "latest" }) end)
    end
    h.command("loop", "superseded"); h.tick()
    assert(fired)
    eq(h.saved().objective, "latest"); eq(h.saved().status, "running")
    eq(h.saved().iteration, 1)
    eq(h.prompts[#h.prompts].text:sub(-6), "latest")
  end)
end

test("old owner cannot complete or cancel replacement during startup", function()
  local h = started()
  local result
  h.hook = function(name)
    if name ~= "new" then return end
    h.spawn(function()
      result = h.tools.loop_complete.handler({ summary = "old work done" }, {
        session_id = function() return "s1" end, task_id = function() return "main" end,
      })
    end)
    h.emit("TurnEnd", { session_id = "s1", reason = "cancelled", cost = 9 })
  end
  h.command("loop", "replacement")
  eq(result.is_error, true)
  eq(h.saved().status, "running"); eq(h.saved().cost, 0); eq(#h.prompts, 2)
end)

for _, point in ipairs({ "metadata", "fs_read", "mkdir", "write", "new" }) do
  test("new loop supersedes resume at " .. point, function()
    local old = started(); old.command("loop-stop")
    local h = host(old.files, old.json)
    local fired = false
    h.hook = function(name)
      if fired or name ~= point then return end
      fired = true
      h.spawn(function() h.commands.loop.handler({ args = "replacement" }) end)
    end
    h.command("loop-resume"); h.tick()
    assert(fired)
    eq(h.saved().objective, "replacement"); eq(h.saved().status, "running")
    eq(h.prompts[#h.prompts].text:sub(-11), "replacement")
  end)
end

test("latest of three overlapping starts wins", function()
  local h = host()
  local launches = 0
  h.hook = function(name)
    if name ~= "read" or launches == 2 then return end
    launches = launches + 1
    local objective = "replacement " .. launches
    h.spawn(function() h.commands.loop.handler({ args = objective }) end)
  end
  h.command("loop", "old"); h.tick()
  eq(h.saved().objective, "replacement 2"); eq(#h.prompts, 1)
end)

test("completion ownership, summary, main-only, durable idempotence", function()
  local h = started()
  eq(h.complete("", "s1").is_error, true)
  eq(h.complete("done", "other").is_error, true)
  eq(h.complete("done", "s1", "sub").is_error, true)
  assert(not h.complete("verified all", "s1").is_error)
  assert(not h.complete("replacement", "s1").is_error)
  eq(h.saved().summary, "verified all")
  h.finish(); h.tick(); eq(h.created, 0); eq(h.saved().status, "completed")
  h.command("loop-resume"); eq(h.created, 0)
end)

test("completion beats pending timer", function()
  local h = started(); h.finish()
  assert(not h.complete("all done", "s1").is_error)
  h.tick(); eq(h.created, 0)
end)

test("stop keeps work, explicit fresh resume", function()
  local h = started()
  h.command("loop-stop")
  eq(h.sessions.s1.status, "working")
  h.finish(); h.tick(); eq(h.created, 0)
  h.command("loop-resume")
  eq(h.created, 1); eq(h.saved().iteration, 2); eq(#h.prompts, 2)
end)

for _, status in ipairs({ "working", "needs_input" }) do
  test("resume during " .. status .. " waits for normal finish and idle", function()
    local h = started()
    h.command("loop-stop")
    h.sessions.s1.status = status
    h.command("loop-resume"); h.tick()
    eq(h.sessions.s1.status, status)
    eq(h.saved().status, "running"); eq(h.created, 0); eq(#h.prompts, 1)
    h.command("loop-resume"); eq(h.created, 0)
    h.sessions.s1.status = "working"
    h.emit("SessionStatusChanged", { session_id = "s1", status = "working" })
    h.drain(); h.tick(); eq(h.created, 0)
    h.finish("finished", "working"); h.tick(); eq(h.created, 0)
    h.sessions.s1.status = "idle"
    h.emit("SessionStatusChanged", { session_id = "s1", status = "idle" })
    h.drain(); h.tick(); h.tick()
    eq(h.created, 1); eq(#h.prompts, 2); eq(h.saved().iteration, 2)
    eq(h.saved().cost, 0.25); eq(h.saved().cost_reports, 1)
    eq(h.saved().resume_parent, nil)
    h.finish(); h.tick(); eq(h.created, 2)
  end)
end

test("resume adopts a manual turn after interruption", function()
  local h = started(); h.finish("cancelled")
  h.sessions.s1.status = "working"
  h.emit("TurnStart", { session_id = "s1", text = "continue the work" }); h.drain()
  h.command("loop-resume"); h.tick(); eq(h.created, 0)
  h.finish(); h.tick()
  eq(h.created, 1); eq(h.saved().cost, 0.5); eq(h.saved().cost_reports, 2)
end)

test("resume waits for focused turn rather than old owner", function()
  local h = started(); h.command("loop-stop")
  h.sessions.other = copy(h.sessions.s1)
  h.sessions.other.id = "other"
  h.sessions.other.settings = { spec = "other", thinking = "off", fast = true }
  h.focus = "other"
  h.command("loop-resume")
  eq(h.saved().owner, "s1"); eq(h.saved().sessions[1].id, "s1")
  eq(h.complete("old owner finished", "s1").is_error, true)
  h.finish("finished", "idle", "s1"); h.tick(); eq(h.created, 0)
  h.finish("finished", "idle", "other"); h.tick()
  eq(h.created, 1); eq(h.saved().iteration, 2); eq(h.saved().owner, "n1")
  eq(h.sessions.n1.settings.spec, "other"); eq(h.saved().cost_reports, 1)
end)

for _, point in ipairs({ "read", "mkdir", "write" }) do
  test("finish racing resume at " .. point .. " is not lost", function()
    local h = started(); h.command("loop-stop")
    local fired = false
    h.hook = function(name)
      if fired or name ~= point then return end
      fired = true
      h.sessions.s1.status = "idle"
      h.emit("TurnEnd", { session_id = "s1", reason = "finished", cost = 0.25 })
    end
    h.command("loop-resume"); h.tick(); h.tick()
    eq(h.created, 1); eq(#h.prompts, 2)
  end)
end

for _, action in ipairs({ "stop", "cancelled", "error", "queued", "manual", "reload", "write" }) do
  test("armed resume is revoked by " .. action, function()
    local h = started(); h.command("loop-stop")
    if action == "write" then h.fail.write = "disk full" end
    h.command("loop-resume")
    h.fail.write = nil
    if action == "stop" then h.command("loop-stop")
    elseif action == "error" then h.emit("TurnError", { session_id = "s1", message = "provider failed" })
    elseif action == "queued" then h.sessions.s1.queue.count = 1
    elseif action == "manual" then h.emit("TurnStart", { session_id = "s1" })
    elseif action == "reload" then h.emit("SessionEnd", { session_id = "s1", reason = "reload" }) end
    h.drain(); h.finish(action == "cancelled" and "cancelled" or "finished"); h.tick()
    eq(h.created, 0); eq(#h.prompts, 1)
    eq(h.saved().status, action == "stop" and "stopped" or "interrupted")
  end)
end

test("stop racing busy resume persistence revokes continuation", function()
  local h = started(); h.command("loop-stop")
  local fired = false
  h.hook = function(name)
    if fired or name ~= "write" then return end
    fired = true
    h.spawn(function() h.commands["loop-stop"].handler({}) end)
  end
  h.command("loop-resume"); h.finish(); h.tick()
  eq(h.saved().status, "stopped"); eq(h.created, 0); eq(#h.prompts, 1)
end)

test("owning turn can complete an armed resume", function()
  local h = started(); h.command("loop-stop"); h.command("loop-resume")
  assert(not h.complete("all verified", "s1").is_error)
  h.finish(); h.tick(); eq(h.created, 0); eq(h.saved().status, "completed")
end)

for _, case in ipairs({ "queued", "plan", "headless", "wrong" }) do
  test("busy resume still rejects " .. case, function()
    local h = started(); h.command("loop-stop")
    if case == "queued" then h.sessions.s1.queue.count = 1
    elseif case == "plan" then h.sessions.s1.mode = "plan"
    elseif case == "headless" then h.sessions.s1.queue = nil
    else h.sessions.s1.cwd = "/elsewhere" end
    h.command("loop-resume"); h.finish(); h.tick()
    eq(h.created, 0); eq(h.saved().status, "stopped")
  end)
end

test("reload can resume an in-flight turn explicitly", function()
  local h = started(); h.command("loop-stop"); h.command("loop-resume")
  local reload = host(h.files, h.json)
  reload.sessions.s1.status = "working"
  reload.command("loop-status"); eq(reload.saved().status, "interrupted")
  reload.command("loop-resume"); reload.tick(); eq(reload.created, 0)
  reload.finish(); reload.tick(); eq(reload.created, 1)
end)

test("resume rechecks a pending rollover without an idle event", function()
  local h = started(); h.finish("finished", "working"); h.tick()
  eq(h.saved().status, "rollover_pending"); eq(h.created, 0)
  h.sessions.s1.status = "idle"
  h.command("loop-resume"); h.tick()
  eq(h.created, 1); eq(h.saved().iteration, 2); eq(#h.prompts, 2)
end)

for _, status in ipairs({ "idle", "working" }) do
  test("reload discards persisted handoff flags before " .. status .. " resume", function()
    local h = started(); h.finish()
    local _, text = next(h.files)
    h.json[text].handoff, h.json[text].wake = true, true
    local reload = host(h.files, h.json)
    reload.sessions.s1.status = status
    reload.command("loop-resume")
    if status == "working" then reload.finish(); reload.tick() end
    eq(reload.created, 1); eq(reload.saved().iteration, 2)
    eq(reload.saved().handoff, nil); eq(reload.saved().wake, nil)
    reload.finish(); reload.tick(); eq(reload.created, 2)
  end)
end

test("handoff execution flags are never persisted", function()
  local h = started(); h.finish(); h.tick()
  eq(h.created, 1); eq(h.saved().handoff, nil); eq(h.saved().wake, nil)
end)

test("unexpected handoff errors interrupt instead of wedging resume", function()
  local h = started(); h.finish()
  local original = maki.session.read
  maki.session.read = function() error("unexpected read failure") end
  h.tick()
  eq(h.saved().status, "interrupted"); eq(h.created, 0)
  assert(h.saved().reason:find("unexpected read failure", 1, true))
  maki.session.read = original
  h.command("loop-resume"); eq(h.created, 1)
end)

test("question suspension and answer do not end iteration", function()
  local h = started()
  h.sessions.s1.status = "needs_input"
  h.emit("SessionStatusChanged", { session_id = "s1", status = "needs_input" })
  h.drain(); h.tick(); eq(h.created, 0); eq(h.saved().status, "running")
  h.sessions.s1.status = "working"
  h.emit("SessionStatusChanged", { session_id = "s1", status = "working" })
  h.drain(); h.finish(); h.tick(); eq(h.created, 1)
end)

for _, case in ipairs({ "queued", "manual", "needs_input", "cwd", "plan" }) do
  test("handoff rejects " .. case, function()
    local h = started(); h.finish()
    if case == "queued" then h.sessions.s1.queue.count = 1
    elseif case == "manual" then h.emit("TurnStart", { session_id = "s1" })
    elseif case == "needs_input" then
      h.sessions.s1.status = case
      h.emit("SessionStatusChanged", { session_id = "s1", status = case })
    elseif case == "cwd" then h.sessions.s1.cwd = "/other"
    elseif case == "plan" then h.sessions.s1.mode = "plan" end
    h.drain(); h.tick(); eq(h.created, 0); eq(h.saved().status, "interrupted")
  end)
end

for _, command in ipairs({ "loop", "loop-forever" }) do
  for _, source in ipairs({ "event", "snapshot" }) do
    for _, result in ipairs({ "started", "queued" }) do
      test(command .. " resolves background " .. source .. " work with " .. result .. " cleanup", function()
        local h = host(); h.command(command, "original objective")
        if source == "event" then
          h.emit("TaskStatusChanged", { session_id = "s1", id = "bg", status = "working" }); h.drain()
        else
          h.sessions.s1.tasks[2] = { id = "bg", status = "working", tool = "bash" }
        end
        h.tick(); eq(#h.prompts, 1)
        h.prompt_result = result
        h.finish("finished", "working")
        h.emit("SessionStatusChanged", { session_id = "s1", status = "working" }); h.drain(); h.tick()
        eq(#h.prompts, 1); eq(h.created, 0)
        h.tick(15 * 60 * 1000 - 1); h.tick(); eq(#h.prompts, 1)
        h.tick(1); h.tick()
        eq(h.created, 0); eq(#h.prompts, 2); eq(h.prompts[2].owner, "s1")
        assert(h.prompts[2].text:find("bg", 1, true)); assert(h.prompts[2].text:find("task_stop", 1, true))
        eq(h.saved().iteration, 1); eq(h.saved().status, "running")
        h.emit("TaskStatusChanged", { session_id = "s1", id = "bg", status = "working" })
        h.drain(); h.tick(); h.tick(); eq(#h.prompts, 2)
        if result == "queued" then
          h.finish("finished", "working"); eq(h.saved().cost, 0.25)
          h.emit("TurnStart", { session_id = "s1" }); h.drain()
        end
        h.sessions.s1.tasks[2] = { id = "bg", status = "cancelled" }
        h.emit("TaskStatusChanged", { session_id = "s1", id = "bg", status = "cancelled" }); h.drain()
        h.prompt_result = nil
        h.finish(); h.tick()
        eq(h.created, 1); eq(#h.prompts, 3); eq(h.saved().iteration, 2)
        eq(h.saved().cost, 0.5); eq(h.saved().cost_reports, 2)
        eq(h.prompts[3].text, h.prompts[1].text)
      end)
    end
  end
end

for _, command in ipairs({ "loop", "loop-forever" }) do
  test(command .. " background wakeup cancels the nudge and continues the iteration", function()
    local h = host(); h.command(command, "objective")
    h.sessions.s1.tasks[2] = { id = "bg", status = "working" }
    h.finish("finished", "working"); h.tick(); h.tick(14 * 60 * 1000)
    h.sessions.s1.tasks[2].status = "done"
    h.emit("TaskStatusChanged", { session_id = "s1", id = "bg", status = "done" })
    h.emit("TurnStart", { session_id = "s1", text = "" }); h.drain()
    eq(h.saved().status, "running"); eq(h.saved().iteration, 1)
    h.nudge(); eq(#h.prompts, 1); eq(h.created, 0)
    h.finish(); h.tick()
    eq(h.created, 1); eq(#h.prompts, 2); eq(h.saved().cost_reports, 2)
    eq(h.prompts[2].text, h.prompts[1].text)
  end)

  test(command .. " starts a fresh wait after a background wakeup finishes", function()
    local h = host(); h.command(command, "objective")
    h.sessions.s1.tasks[2] = { id = "bg", status = "working" }
    h.finish("finished", "working"); h.tick(); h.tick(14 * 60 * 1000)
    h.emit("TurnStart", { session_id = "s1", text = "" }); h.drain()
    h.finish("finished", "working"); h.tick()
    h.tick(14 * 60 * 1000); h.tick(); eq(#h.prompts, 1)
    h.tick(60 * 1000); h.tick(); eq(#h.prompts, 2)
    assert(h.prompts[2].text:find("hanging", 1, true))
    assert(h.prompts[2].text:find("active work we should block on", 1, true))
  end)
end

for _, point in ipairs({ "read", "focus", "current", "tasks", "model" }) do
  test("background wakeup revokes in-flight rollover at " .. point, function()
    local h = started(); h.finish()
    local fired = false
    h.hook = function(name)
      if fired or name ~= point then return end
      fired = true
      h.sessions.s1.status = "working"
      h.emit("TurnStart", { session_id = "s1", text = "" })
    end
    h.tick(); h.tick(); assert(fired)
    eq(h.created, 0); eq(h.saved().status, "running")
    h.hook = nil
    h.finish(); h.tick(); eq(h.created, 1)
  end)
end

for _, action in ipairs({ "stop", "complete", "manual", "missing_text", "reload", "replace" }) do
  test("pending nudge is revoked by " .. action, function()
    local h = started(); h.sessions.s1.tasks[2] = { id = "bg", status = "working" }
    h.finish("finished", "working"); h.tick()
    if action == "stop" then h.command("loop-stop")
    elseif action == "complete" then h.complete("done")
    elseif action == "manual" then h.emit("TurnStart", { session_id = "s1", text = "do something else" })
    elseif action == "missing_text" then h.emit("TurnStart", { session_id = "s1" })
    elseif action == "reload" then h.emit("SessionEnd", { session_id = "s1", reason = "reload" })
    else h.command("loop-forever", "replacement") end
    h.drain()
    local prompts = #h.prompts
    h.nudge(); eq(#h.prompts, prompts)
    if action == "manual" or action == "missing_text" then eq(h.saved().status, "interrupted") end
  end)
end

test("task status updates do not postpone or duplicate the nudge", function()
  local h = started(); h.sessions.s1.tasks[2] = { id = "bg", status = "working" }
  h.finish("finished", "working"); h.tick()
  for _ = 1, 14 do
    h.tick(60 * 1000)
    h.emit("TaskStatusChanged", { session_id = "s1", id = "bg", status = "working" })
    h.emit("SessionStatusChanged", { session_id = "s1", status = "working" })
    h.drain(); h.tick(); eq(#h.prompts, 1)
  end
  h.tick(60 * 1000); h.tick(); eq(#h.prompts, 2)
  h.nudge(); eq(#h.prompts, 2)
end)

for _, point in ipairs({ "read", "tasks", "mkdir", "write" }) do
  test("background wakeup revokes a due nudge at " .. point, function()
    local h = started(); h.sessions.s1.tasks[2] = { id = "bg", status = "working" }
    h.finish("finished", "working"); h.tick()
    local fired = false
    h.hook = function(name)
      if fired or name ~= point then return end
      fired = true
      h.emit("TurnStart", { session_id = "s1", text = "" })
    end
    h.nudge(); assert(fired); eq(#h.prompts, 1); eq(h.saved().status, "running")
    h.hook = nil
    h.sessions.s1.tasks[2].status = "done"
    h.finish(); h.tick(); eq(h.created, 1)
  end)
end

test("finishing background work before the timeout avoids a nudge", function()
  local h = started(); h.sessions.s1.tasks[2] = { id = "bg", status = "working" }
  h.finish("finished", "working"); h.tick()
  h.sessions.s1.tasks[2].status = "cancelled"; h.sessions.s1.status = "idle"
  h.emit("TaskStatusChanged", { session_id = "s1", id = "bg", status = "cancelled" }); h.drain(); h.tick()
  eq(h.created, 1); eq(#h.prompts, 2)
  h.nudge(); eq(#h.prompts, 2)
end)

test("background wakeups after loop-stop do not revive continuation", function()
  local h = started(); h.finish(); h.command("loop-stop")
  h.emit("TurnStart", { session_id = "s1", text = "" }); h.drain()
  h.finish(); h.nudge(); eq(h.created, 0); eq(h.saved().status, "stopped")
end)

test("queued nudge survives a background wakeup without another nudge", function()
  local h = started(); h.sessions.s1.tasks[2] = { id = "bg", status = "working" }
  h.finish("finished", "working"); h.tick(); h.prompt_result = "queued"; h.nudge()
  h.emit("TurnStart", { session_id = "s1", text = "" }); h.drain()
  h.emit("TurnStart", { session_id = "s1", text = h.prompts[2].text }); h.drain()
  h.nudge(); eq(#h.prompts, 2); eq(h.saved().status, "running")
  h.sessions.s1.tasks[2].status = "done"; h.prompt_result = nil
  h.finish(); h.tick(); eq(h.created, 1)
end)

test("cleanup repeats only after another normally finished turn", function()
  local h = started()
  h.sessions.s1.tasks[2] = { id = "bg", status = "working" }
  h.finish(); h.tick(); eq(#h.prompts, 1); h.nudge(); eq(#h.prompts, 2); eq(h.created, 0)
  h.tick(); eq(#h.prompts, 2)
  h.finish(); h.tick(); eq(#h.prompts, 2); h.nudge(); eq(#h.prompts, 3); eq(h.created, 0)
  h.finish("cancelled"); h.tick()
  eq(#h.prompts, 3); eq(h.saved().status, "interrupted")
end)

test("cleanup does not revive a stopped or completed loop", function()
  for _, action in ipairs({ "stop", "complete" }) do
    local h = started()
    h.sessions.s1.tasks[2] = { id = "bg", status = "working" }
    if action == "stop" then h.command("loop-stop") else h.complete("done") end
    h.finish(); h.tick(); eq(#h.prompts, 1); eq(h.created, 0)
  end
end)

test("finished tasks and wrappers do not trigger cleanup from stale events", function()
  local h = started()
  h.emit("TaskStatusChanged", { session_id = "s1", id = "bg", status = "working" })
  h.drain()
  h.sessions.s1.tasks[2] = { id = "bg", status = "done" }
  h.sessions.s1.tasks[3] = { id = "batch", status = "working", wrapper = true }
  h.finish(); h.tick(); eq(h.created, 1); eq(#h.prompts, 2)
  eq(h.prompts[2].text, h.prompts[1].text)
end)

test("cleanup targets an armed resume parent rather than the old owner", function()
  local h = started(); h.command("loop-stop")
  h.sessions.other = copy(h.sessions.s1); h.sessions.other.id = "other"; h.focus = "other"
  h.sessions.other.tasks[2] = { id = "bg", status = "working" }
  h.command("loop-resume"); h.finish("finished", "working"); h.tick(); h.nudge()
  eq(#h.prompts, 2); eq(h.prompts[2].owner, "other"); eq(h.created, 0)
  h.sessions.other.tasks[2].status = "done"
  h.finish(); h.tick(); eq(h.created, 1); eq(h.saved().iteration, 2)
end)

for _, failure in ipairs({ "write", "prompt" }) do
  test("cleanup failure interrupts on " .. failure, function()
    local h = started(); h.sessions.s1.tasks[2] = { id = "bg", status = "working" }
    h.finish("finished", "working"); h.tick(); h.fail[failure] = "cleanup failure"
    h.nudge(); h.fail[failure] = nil
    h.command("loop-status"); assert(h.notes[#h.notes]:find("interrupted", 1, true))
    h.tick(); eq(#h.prompts, 1); eq(h.created, 0)
  end)
end

for _, point in ipairs({ "focus", "current", "read", "tasks", "mkdir", "write" }) do
  test("stop racing cleanup at " .. point, function()
    local h = started(); h.sessions.s1.tasks[2] = { id = "bg", status = "working" }
    h.finish("finished", "working"); h.tick()
    local fired = false
    h.hook = function(name)
      if fired or name ~= point then return end
      fired = true
      h.spawn(function() h.commands["loop-stop"].handler({}) end)
    end
    h.nudge(); h.tick(); assert(fired)
    eq(#h.prompts, 1); eq(h.created, 0); eq(h.saved().status, "stopped")
  end)
end

for _, reason in ipairs({ "cancelled", "max_tokens", "max_turns", "dropped" }) do
  test("abnormal ending " .. reason, function()
    local h = started(); h.finish(reason); h.tick()
    eq(h.saved().status, "interrupted"); eq(h.created, 0)
  end)
end

for _, event in ipairs({ "TurnError", "SessionReset", "SessionEnd" }) do
  test("abnormal lifecycle " .. event, function()
    local h = started()
    h.emit(event, { session_id = "s1", reason = "load", message = "provider failed" })
    h.drain(); h.finish(); h.tick(); eq(h.created, 0); eq(h.saved().status, "interrupted")
  end)
end

for _, reason in ipairs({ "shutdown", "reload", "replaced", "completed" }) do
  test("filesystem-only teardown " .. reason, function()
    local h = started(); h.finish()
    h.detached = true
    h.emit("SessionEnd", { session_id = "other", reason = reason, deadline_ms = 100 })
    h.drain(); h.tick(); eq(h.saved().status, "interrupted"); eq(h.created, 0)
  end)
end

for _, failure in ipairs({ "mkdir", "write", "encode", "new", "focus", "model", "tasks", "read", "prompt" }) do
  test("failure prevents retries " .. failure, function()
    local h = started(); h.finish()
    h.fail[failure] = "injected " .. failure
    h.tick()
    h.fail[failure] = nil
    h.emit("SessionStatusChanged", { session_id = h.focus, status = "idle" })
    h.drain(); h.tick()
    eq(#h.prompts, 1)
    h.command("loop-status")
    assert(h.notes[#h.notes]:find("interrupted", 1, true))
  end)
end

for _, failure in ipairs({ "mkdir", "write", "encode", "prompt" }) do
  test("initial launch failure " .. failure, function()
    local h = host(); h.fail[failure] = "failure"; h.command("loop", "work")
    eq(#h.prompts, 0); h.tick(); eq(h.created, 0)
  end)
end

test("queued prompt interrupts", function()
  local h = host(); h.prompt_result = "queued"; h.command("loop", "work")
  eq(h.saved().status, "interrupted"); h.finish(); h.tick(); eq(h.created, 0)
end)

test("failed completion write never reports success, retry is durable", function()
  local h = started(); h.fail.write = "disk full"
  eq(h.complete("done", "s1").is_error, true)
  h.finish(); h.tick(); eq(h.created, 0)
  h.fail.write = nil
  assert(not h.complete("done", "s1").is_error)
  eq(h.saved().status, "completed")
end)

test("reload requires resume, project isolation and normalized keys", function()
  local h = started()
  local next = host(h.files, h.json)
  next.command("loop-status")
  eq(next.saved().status, "interrupted"); next.tick(); eq(#next.prompts, 0)
  next.cwd = "/project/./child/.."
  next.command("loop-resume"); eq(next.created, 1)
  next.command("loop-stop"); next.sessions[next.focus].status = "idle"
  next.cwd = "/different"; next.sessions[next.focus].cwd = "/different"
  next.command("loop-resume"); eq(next.created, 1)
  next.command("loop", "separate")
  eq(#next.prompts, 2)
  eq(next.saved().objective, "separate")
  next.cwd = "/project/./child/.."
  eq(next.saved().objective, "do the work")
  eq(next.saved().status, "stopped")
  next.cwd = "/missing"
  eq(next.saved(), nil)
  local n = 0; for path in pairs(next.files) do n = n + 1; assert(not path:find("/project", 1, true)) end
  eq(n, 2)
end)

test("JSON null optional state fields retain nil semantics on reload", function()
  local h = started()
  local _, text = next(h.files)
  local s = h.json[text]
  s.reason, s.resume_parent, s.summary = null, null, null
  local reload = host(h.files, h.json)
  reload.command("loop-status")
  eq(reload.saved().status, "interrupted")
  eq(reload.saved().resume_parent, nil)
  eq(reload.saved().summary, nil)
  reload.command("loop-resume")
  eq(reload.created, 1)
  eq(#reload.prompts, 1)
  assert(not reload.complete("done").is_error)
end)

for _, field in ipairs({ "root", "objective", "sessions", "record", "summary" }) do
  test("reject JSON null in required state " .. field, function()
    local h = started()
    local _, text = next(h.files)
    local s = h.json[text]
    if field == "root" then h.json[text] = null
    elseif field == "record" then s.sessions[1] = null
    elseif field == "summary" then s.status, s.summary = "completed", null
    else s[field] = null end
    local reload = host(h.files, h.json)
    reload.command("loop-resume"); reload.tick()
    eq(#reload.prompts, 0); eq(reload.created, 0)
    assert(reload.notes[#reload.notes]:find("Corrupt", 1, true) or reload.notes[#reload.notes]:find("Invalid", 1, true))
  end)
end

for _, corrupt in ipairs({ "json", "version", "owner", "cost", "objective", "records", "summary", "cwd", "resume_parent",
  "sparse", "object", "mixed", "zero", "negative", "fractional", "extra", "empty", "forever", "forever_completed" }) do
  test("reject corrupt state " .. corrupt, function()
    local h = started()
    local path, text = next(h.files)
    local s = h.json[text]
    if corrupt == "json" then h.files[path] = "broken"
    elseif corrupt == "version" then s.version = 99
    elseif corrupt == "forever" then s.forever = "true"
    elseif corrupt == "forever_completed" then s.forever, s.status, s.summary = true, "completed", "done"
    elseif corrupt == "owner" then s.owner = "wrong"
    elseif corrupt == "resume_parent" then s.resume_parent = {}
    elseif corrupt == "cost" then s.cost = -1
    elseif corrupt == "objective" then s.objective = " "
    elseif corrupt == "records" then s.sessions[1].iteration = 3
    elseif corrupt == "sparse" then s.sessions[3] = copy(s.sessions[1])
    elseif corrupt == "object" then s.sessions = { ["1"] = s.sessions[1] }
    elseif corrupt == "mixed" then s.sessions.hidden = copy(s.sessions[1])
    elseif corrupt == "zero" then s.sessions[0] = copy(s.sessions[1])
    elseif corrupt == "negative" then s.sessions[-1] = copy(s.sessions[1])
    elseif corrupt == "fractional" then s.sessions[1.5] = copy(s.sessions[1])
    elseif corrupt == "extra" then s.sessions[2] = copy(s.sessions[1])
    elseif corrupt == "empty" then s.sessions = {}
    elseif corrupt == "summary" then s.status, s.summary = "completed", nil
    elseif corrupt == "cwd" then s.cwd = "/wrong" end
    local reload = host(h.files, h.json)
    reload.command("loop-resume"); reload.tick(); eq(#reload.prompts, 0); eq(reload.created, 0)
    reload.command("loop", "new objective")
    eq(#reload.prompts, 1); eq(reload.saved().objective, "new objective")
    eq(reload.saved().status, "running")
  end)
end

for _, field in ipairs({ "spec", "thinking", "fast", "mode", "cwd" }) do
  test("inheritance mismatch " .. field, function()
    local h = started(); h.finish()
    h.new_mutate = function(s)
      if field == "mode" then s.mode = "plan"
      elseif field == "cwd" then s.cwd = "/other"
      elseif field == "fast" then s.settings.fast = true
      else s.settings[field] = "different" end
    end
    h.tick(); eq(#h.prompts, 1); eq(h.saved().status, "interrupted")
  end)
end

for _, action in ipairs({ "stop", "complete", "teardown" }) do
  for _, point in ipairs({ "read", "focus", "current", "tasks", "model", "new", "mkdir", "write", "prompt" }) do
    test("race " .. action .. " at " .. point, function()
      local h = started(); h.finish()
      local fired = false
      h.hook = function(name)
        if fired or name ~= point then return end
        fired = true
        if action == "stop" then h.spawn(function() h.commands["loop-stop"].handler({}) end)
        elseif action == "complete" then h.spawn(function()
          h.tools.loop_complete.handler({ summary = "done" }, { session_id = function() return h.created > 0 and "n1" or "s1" end, task_id = function() return "main" end })
        end)
        else h.emit("SessionEnd", { session_id = "s1", reason = "reload" }) end
      end
      h.tick(); h.tick()
      if point ~= "prompt" then eq(#h.prompts, 1) end
      assert(h.created <= 1)
      h.command("loop-status")
      if action == "stop" then eq(h.saved().status, "stopped") end
    end)
  end
end

test("idle event arriving during handoff read is not lost", function()
  local h = started(); h.finish("finished", "working")
  local original = maki.session.read
  local once = false
  maki.session.read = function(opts)
    if not once then
      once = true
      local snapshot = copy(h.sessions[opts.session])
      h.sessions.s1.status = "idle"
      h.emit("SessionStatusChanged", { session_id = "s1", status = "idle" })
      coroutine.yield("yield")
      return snapshot
    end
    return original(opts)
  end
  h.tick(); h.tick(); eq(h.created, 1)
end)

test("stop while initial command is reading prevents launch", function()
  local h = host()
  local fired = false
  h.hook = function(name)
    if name == "read" and not fired then
      fired = true
      h.spawn(function() h.commands["loop-stop"].handler({}) end)
    end
  end
  h.command("loop", "work"); h.tick(); eq(#h.prompts, 0)
end)

test("queued user input arriving during model inspection is preserved", function()
  local h = started(); h.finish()
  h.hook = function(name) if name == "model" then h.sessions.s1.queue.count = 1 end end
  h.tick(); eq(h.created, 0); eq(h.sessions.s1.queue.count, 1)
end)

print(string.format("PASS: %d deterministic tests", count))
