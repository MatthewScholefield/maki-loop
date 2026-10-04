local function copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = copy(x) end
  return out
end

local function eq(a, b)
  assert(a == b, tostring(a) .. " ~= " .. tostring(b))
end

local function host(files, json)
  local h = { files = files or {}, json = json or {}, commands = {}, tools = {}, events = {}, timers = {},
    ready = {}, notes = {}, sessions = {}, focus = "s1", created = 0, prompts = {}, calls = {}, fail = {}, detached = false }
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
  function h.tick()
    local timers = h.timers
    h.timers = {}
    for _, t in ipairs(timers) do if not t.stopped then h.spawn(t.fn) end end
    h.drain()
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
  local m = { api = {}, fs = {}, env = {}, uv = {}, session = {}, model = {}, task = {}, json = {}, async = {} }
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
    eq(ms, 0)
    local t = { fn = fn, stop = function(self) self.stopped = true end }
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
  m.json.decode = function(text) if not h.json[text] then return nil, "malformed JSON" end; return copy(h.json[text]) end
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
    assert(opts.prompt == nil)
    eq(opts.focus, false)
    local err = ui("new")
    if err then return nil, err end
    h.created = h.created + 1
    local s = copy(h.sessions[h.focus])
    s.id, s.status, s.queue, s.tasks = "n" .. h.created, "idle", { count = 0 }, { { id = "main" } }
    if h.new_mutate then h.new_mutate(s) end
    h.sessions[s.id] = s
    return s.id
  end
  m.session.prompt = function(text, opts)
    local err = ui("prompt")
    if err then return nil, err end
    eq(h.saved().owner, opts.session)
    eq(h.saved().status, "running")
    h.prompts[#h.prompts + 1] = { text = text, owner = opts.session }
    h.sessions[opts.session].status = "working"
    h.emit("TurnStart", { session_id = opts.session, text = text })
    return h.prompt_result or "started"
  end
  _G.maki = m
  dofile("lua/loop.lua")
  return h
end

local count = 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if not ok then error(name .. ": " .. tostring(err), 0) end
  count = count + 1
  print("ok " .. count .. " - " .. name)
end

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

for _, case in ipairs({ "blank", "busy", "queued", "plan", "headless", "wrong" }) do
  test("reject start " .. case, function()
    local h = host()
    local s = h.sessions.s1
    if case == "busy" then s.status = "working" end
    if case == "queued" then s.queue.count = 1 end
    if case == "plan" then s.mode = "plan" end
    if case == "headless" then s.queue = nil end
    if case == "wrong" then s.cwd = "/elsewhere" end
    h.command("loop", case == "blank" and " \n " or "work")
    eq(#h.prompts, 0); eq(h.created, 0)
  end)
end

test("duplicate commands and unrelated lifecycle", function()
  local h = started()
  h.command("loop", "different")
  eq(h.saved().objective, "do the work")
  for _, e in ipairs({ "TurnEnd", "TurnError", "SessionReset", "SessionEnd" }) do
    h.emit(e, { session_id = "other", reason = "finished" })
  end
  h.drain(); h.tick(); eq(h.saved().status, "running"); eq(h.created, 0)
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

test("question suspension and answer do not end iteration", function()
  local h = started()
  h.sessions.s1.status = "needs_input"
  h.emit("SessionStatusChanged", { session_id = "s1", status = "needs_input" })
  h.drain(); h.tick(); eq(h.created, 0); eq(h.saved().status, "running")
  h.sessions.s1.status = "working"
  h.emit("SessionStatusChanged", { session_id = "s1", status = "working" })
  h.drain(); h.finish(); h.tick(); eq(h.created, 1)
end)

for _, case in ipairs({ "queued", "manual", "working", "needs_input", "task_event", "task_snapshot", "cwd", "plan" }) do
  test("handoff rejects " .. case, function()
    local h = started(); h.finish()
    if case == "queued" then h.sessions.s1.queue.count = 1
    elseif case == "manual" then h.emit("TurnStart", { session_id = "s1" })
    elseif case == "working" or case == "needs_input" then
      h.sessions.s1.status = case
      h.emit("SessionStatusChanged", { session_id = "s1", status = case })
    elseif case == "task_event" then h.emit("TaskStatusChanged", { session_id = "s1", id = "t", status = "working" })
    elseif case == "task_snapshot" then h.sessions.s1.tasks[2] = { id = "t", status = "working" }
    elseif case == "cwd" then h.sessions.s1.cwd = "/other"
    elseif case == "plan" then h.sessions.s1.mode = "plan" end
    h.drain(); h.tick(); eq(h.created, 0); eq(h.saved().status, "interrupted")
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

for _, corrupt in ipairs({ "json", "version", "owner", "cost", "objective", "records", "summary", "cwd",
  "sparse", "object", "mixed", "zero", "negative", "fractional", "extra", "empty" }) do
  test("reject corrupt state " .. corrupt, function()
    local h = started()
    local path, text = next(h.files)
    local s = h.json[text]
    if corrupt == "json" then h.files[path] = "broken"
    elseif corrupt == "version" then s.version = 99
    elseif corrupt == "owner" then s.owner = "wrong"
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
