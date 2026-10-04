local states, timer, active, loading = {}, nil, nil, false
local writes = maki.async.semaphore(1)
local closed, command_generation = false, 0
local schedule

local function nonblank(s)
  return type(s) == "string" and s:find("%S") ~= nil
end

local function integer(n)
  return type(n) == "number" and n >= 0 and n < math.huge and n == math.floor(n)
end

local function valid(s, cwd)
  local statuses = { running = true, rollover_pending = true, stopped = true, interrupted = true, completed = true }
  return type(s) == "table" and s.version == 1 and s.cwd == cwd
    and nonblank(s.objective) and nonblank(s.id) and nonblank(s.owner)
    and integer(s.generation) and integer(s.iteration) and s.iteration > 0
    and statuses[s.status] and type(s.cost) == "number" and s.cost >= 0 and s.cost < math.huge
    and integer(s.cost_reports) and type(s.sessions) == "table"
    and (s.reason == nil or type(s.reason) == "string")
    and (s.summary == nil or nonblank(s.summary))
    and (s.status ~= "completed" or nonblank(s.summary))
end

local function location(cwd)
  local root, err = maki.env.state_dir()
  if err or not root then return nil, err or "state directory unavailable" end
  local key = cwd:gsub(".", function(c) return string.format("%02x", string.byte(c)) end)
  local parts = { root, "loops" }
  for i = 1, #key, 120 do parts[#parts + 1] = key:sub(i, i + 119) end
  return table.concat(parts, "/")
end

local function persist(s)
  local permit = writes:acquire()
  local dir, err = location(s.cwd)
  if dir then
    local ok
    ok, err = maki.fs.mkdir(dir, { parents = true })
    if not err and ok then
      local text
      text, err = maki.json.encode(s)
      if text and not err then
        ok, err = maki.fs.atomic_write(dir .. "/state.json", text)
        if not ok then err = err or "atomic write failed" end
      else err = err or "JSON encode failed" end
    else
      err = err or "mkdir failed"
    end
  end
  permit:release()
  return not err, err
end

local function eligible(s)
  return s and (s.status == "running" or s.status == "rollover_pending")
end

local function revoke(s, status, reason)
  s.generation = s.generation + 1
  s.status, s.reason = status, reason
  if timer then timer:stop(); timer = nil end
end

local function interrupt(s, reason, quiet)
  if not eligible(s) then return end
  revoke(s, "interrupted", reason)
  local ok, err = persist(s)
  if not quiet then maki.notify("Loop interrupted: " .. reason .. (ok and "" or "; save failed: " .. tostring(err)), "warn") end
end

local function token(s)
  local generation, owner, iteration = s.generation, s.owner, s.iteration
  return function()
    return not closed and eligible(s) and s.generation == generation and s.owner == owner and s.iteration == iteration
  end
end

local function call(s, guard, fn, ...)
  if not guard() then return nil, "revoked" end
  local value, err = fn(...)
  if not guard() then return nil, "revoked" end
  if err or value == nil or value == false then
    interrupt(s, tostring(err or "host returned no value"))
    return nil, err or "host returned no value"
  end
  return value
end

local function check(snapshot, cwd, idle)
  if type(snapshot.queue) ~= "table" then return "Interactive TUI required; headless/SDK/ACP are unsupported" end
  if maki.fs.normalize(snapshot.cwd) ~= cwd then return "Wrong project" end
  if snapshot.mode ~= "build" then return "Switch to build mode before using loop" end
  if snapshot.queue.count ~= 0 then return "Queued user work" end
  if idle and snapshot.status ~= "idle" then return "Session is busy" end
end

local function project()
  local cwd, err = maki.uv.cwd()
  if err or not cwd then return nil, nil, err or "cwd unavailable" end
  cwd = maki.fs.normalize(cwd)
  if states[cwd] then return states[cwd], cwd end
  local dir
  dir, err = location(cwd)
  if not dir then return nil, cwd, err end
  local meta
  meta, err = maki.fs.metadata(dir .. "/state.json")
  if err then return nil, cwd, err end
  if not meta then return nil, cwd end
  local text
  text, err = maki.fs.read(dir .. "/state.json")
  if err or not text then return nil, cwd, err or "state read failed" end
  local s
  s, err = maki.json.decode(text)
  if err or not valid(s, cwd) then return nil, cwd, "Corrupt or unsupported loop state" end
  local count = 0
  for i, record in pairs(s.sessions) do
    if not integer(i) or i < 1 or i > s.iteration
      or type(record) ~= "table" or not nonblank(record.id) or not integer(record.iteration) or record.iteration ~= i then
      return nil, cwd, "Invalid iteration records"
    end
    count = count + 1
  end
  if count ~= s.iteration or s.sessions[s.iteration].id ~= s.owner then return nil, cwd, "Invalid owner record" end
  states[cwd] = s
  if eligible(s) then
    revoke(s, "interrupted", "Restart/reload requires explicit /loop-resume")
    local ok
    ok, err = persist(s)
    if not ok then return s, cwd, err end
  end
  return s, cwd
end

local function submit(s, guard)
  local snapshot = call(s, guard, maki.session.read, { session = s.owner })
  if not snapshot then return end
  local reason = check(snapshot, s.cwd, true)
  if reason then interrupt(s, reason); return end
  s.expect_start = true
  local prompt = "Loop iteration: complete one unit of work toward the objective below. Persist progress and verification in the user-specified files. Use normal question tools for ambiguity. Only call loop_complete with a completion summary when the ENTIRE objective is satisfied, not merely one task. Otherwise finish this turn normally; a fresh session will repeat the objective. No prior conversation or summary is supplied.\n\nOriginal objective (verbatim):\n" .. s.objective
  local result = call(s, guard, maki.session.prompt, prompt, { session = s.owner })
  if result and result ~= "started" then interrupt(s, "Prompt was queued instead of started") end
end

local function fresh(s, guard, parent)
  local ok = call(s, guard, maki.session.focus, parent)
  if not ok then return end
  local current = call(s, guard, maki.session.current)
  if not current then return end
  if current ~= parent then interrupt(s, "Focus changed during handoff"); return end
  local snapshot = call(s, guard, maki.session.read, { session = parent })
  if not snapshot then return end
  local reason = check(snapshot, s.cwd, true)
  if reason then interrupt(s, reason); return end
  for _, status in pairs(s.tasks) do
    if status == "working" then interrupt(s, "Active subagent during handoff"); return end
  end
  local tasks = call(s, guard, maki.task.list)
  if not tasks then return end
  for _, task in ipairs(tasks) do
    if task.id ~= "main" and task.status == "working" then interrupt(s, "Active subagent during handoff"); return end
  end
  local model = call(s, guard, maki.model.get)
  if not model then return end
  current = call(s, guard, maki.session.current)
  if not current then return end
  if current ~= parent then interrupt(s, "Focus changed before creation"); return end
  snapshot = call(s, guard, maki.session.read, { session = parent })
  if not snapshot then return end
  reason = check(snapshot, s.cwd, true)
  if reason then interrupt(s, reason); return end
  local id = call(s, guard, maki.session.new, { focus = false })
  if not id then return end
  s.owner, s.iteration, s.status = id, s.iteration + 1, "running"
  s.reason, s.ended, s.expect_start, s.tasks = nil, false, false, {}
  s.sessions[#s.sessions + 1] = { id = id, iteration = s.iteration }
  guard = token(s)
  local saved = call(s, guard, persist, s)
  if not saved then return end
  ok = call(s, guard, maki.session.focus, id)
  if not ok then return end
  local inherited = call(s, guard, maki.model.get)
  if not inherited then return end
  current = call(s, guard, maki.session.current)
  if not current then return end
  if current ~= id or inherited.spec ~= model.spec or inherited.thinking ~= model.thinking or inherited.fast ~= model.fast then
    interrupt(s, "Focused session or inherited model/thinking/fast mismatch"); return
  end
  submit(s, guard)
end

schedule = function(s)
  if closed or s.status ~= "rollover_pending" then return end
  if s.handoff then s.wake = true; return end
  if timer then return end
  local guard = token(s)
  timer = maki.defer_fn(function()
    timer = nil
    if not guard() then return end
    s.handoff = true
    local snapshot = call(s, guard, maki.session.read, { session = s.owner })
    if snapshot then
      local reason = check(snapshot, s.cwd, false)
      if reason then interrupt(s, reason)
      elseif snapshot.status == "idle" then fresh(s, guard, s.owner) end
    end
    s.handoff = false
    if s.wake then s.wake = false; schedule(s) end
  end, 0)
end

local function command(name, nargs, handler)
  maki.api.register_command({ name = name, nargs = nargs, description = name, handler = function(opts)
    if closed then return end
    if loading then maki.notify("Loop command already in progress", "warn"); return end
    loading = true
    local ok, err = pcall(handler, opts)
    loading = false
    if not ok then
      if eligible(active) then interrupt(active, tostring(err)) end
      maki.notify("Loop error: " .. tostring(err), "error")
    end
  end })
end

local function start(opts, resume)
  local command_token = command_generation
  if not resume and not nonblank(opts.args) then maki.notify("A nonblank objective is required", "warn"); return end
  local s, cwd, err = project()
  if err then maki.notify(tostring(err), "error"); return end
  if eligible(active) or eligible(s) then maki.notify("A loop is already active", "warn"); return end
  if resume and (not s or s.status == "completed") then maki.notify("No resumable loop in this project", "warn"); return end
  local parent
  parent, err = maki.session.current()
  if err or not parent then maki.notify("Interactive TUI required: " .. tostring(err), "warn"); return end
  local snapshot
  snapshot, err = maki.session.read({ session = parent })
  if err or not snapshot then maki.notify(tostring(err), "error"); return end
  local reason = check(snapshot, cwd, true)
  if reason then maki.notify(reason, "warn"); return end
  if closed or command_generation ~= command_token then return end
  if not resume then
    s = { version = 1, cwd = cwd, objective = opts.args, id = parent .. ":" .. tostring(snapshot.updated_at),
      generation = 0, iteration = 1, owner = parent, cost = 0, cost_reports = 0,
      sessions = { { id = parent, iteration = 1 } } }
  end
  s.generation, s.status, s.reason = s.generation + 1, "running", nil
  s.ended, s.expect_start, s.tasks = false, false, {}
  states[cwd], active = s, s
  local guard = token(s)
  if not call(s, guard, persist, s) then return end
  maki.notify("Loop starting: unlimited iterations/spend; no automatic progress guarantee. Prior transcripts/tabs are retained. Use /loop-stop to revoke continuation.", "warn")
  if not guard() then return end
  if resume then fresh(s, guard, parent) else submit(s, guard) end
end

command("loop", "+", function(opts) start(opts, false) end)
command("loop-resume", 0, function(opts) start(opts, true) end)
command("loop-status", 0, function()
  local s, _, err = project()
  if err then maki.notify(tostring(err), "error"); return end
  if not s then maki.notify("No loop saved for this project"); return end
  maki.notify(string.format("Loop %s | iteration %d | owner %s | reported cost %.6f (%d reports) | %s%s%s",
    s.status, s.iteration, s.owner, s.cost, s.cost_reports, s.objective,
    s.reason and " | " .. s.reason or "", s.summary and " | " .. s.summary or ""))
end)

maki.api.register_command({ name = "loop-stop", description = "Revoke loop continuation without cancelling current work", handler = function()
  command_generation = command_generation + 1
  local s = active
  if not s then
    local err
    local cwd
    s, cwd, err = project()
    if err then maki.notify(tostring(err), "error"); return end
  end
  if not s or s.status == "completed" then maki.notify("No stoppable loop"); return end
  revoke(s, "stopped", "Manual stop; current work is not cancelled")
  local ok, err = persist(s)
  maki.notify(ok and s.reason or "Stopped; save failed: " .. tostring(err), ok and "info" or "error")
end })

maki.api.register_tool({
  name = "loop_complete", audiences = { "main" },
  description = "End the entire active loop objective, only when all of it is satisfied. Provide a nonempty completion summary with evidence. Inert outside the owning main-agent iteration.",
  schema = { type = "object", properties = { summary = { type = "string" } }, required = { "summary" }, additionalProperties = false },
  handler = function(input, ctx)
    local s = active
    if closed or not s or ctx:task_id() ~= "main" or ctx:session_id() ~= s.owner or not nonblank(input.summary)
      or (not eligible(s) and s.status ~= "completed") then
      return { llm_output = "No matching active main-agent loop, or empty summary", is_error = true }
    end
    if s.status ~= "completed" then
      revoke(s, "completed", "Objective complete")
      s.summary = input.summary
    end
    local generation = s.generation
    local ok, err = persist(s)
    if not ok or s.generation ~= generation or s.status ~= "completed" then
      return { llm_output = "Completion not durably acknowledged: " .. tostring(err or "revoked"), is_error = true }
    end
    return { llm_output = "Loop completed: " .. s.summary }
  end,
})

maki.api.create_autocmd({ "TurnStart", "TurnEnd", "TurnError", "SessionStatusChanged", "TaskStatusChanged", "SessionEnd", "SessionReset" }, {
  callback = function(ev)
    local s, d = active, ev.data
    local teardown = ev.event == "SessionEnd" and ({ shutdown = true, reload = true, replaced = true, completed = true })[d.reason]
    if teardown then
      closed = true
      if timer then timer:stop(); timer = nil end
      if eligible(s) then interrupt(s, "Session teardown: " .. d.reason, true) end
      return
    end
    if not s or d.session_id ~= s.owner then return end
    if ev.event == "TurnEnd" and not s.ended then
      s.ended = true
      if type(d.cost) == "number" and d.cost >= 0 and d.cost < math.huge then
        s.cost, s.cost_reports = s.cost + d.cost, s.cost_reports + 1
      end
      if eligible(s) then
        if d.reason ~= "finished" then interrupt(s, "Turn ended: " .. tostring(d.reason)); return end
        s.status = "rollover_pending"
        local guard = token(s)
        if not call(s, guard, persist, s) then return end
        schedule(s)
      else persist(s) end
      return
    end
    if not eligible(s) then return end
    if ev.event == "TurnStart" then
      if s.status == "running" and s.expect_start then s.expect_start = false
      else interrupt(s, "Manual follow-up turn") end
    elseif ev.event == "TurnError" then interrupt(s, "Turn error: " .. tostring(d.message))
    elseif ev.event == "SessionEnd" or ev.event == "SessionReset" then interrupt(s, "Session lifecycle: " .. tostring(d.reason or ev.event), true)
    elseif ev.event == "TaskStatusChanged" then
      s.tasks[d.id] = d.status
      if s.status == "rollover_pending" then schedule(s) end
    elseif ev.event == "SessionStatusChanged" and s.status == "rollover_pending" then
      if d.status == "needs_input" or d.status == "working" then interrupt(s, "User work after terminal turn") else schedule(s) end
    end
  end,
})
