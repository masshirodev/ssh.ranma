-- ssh: a picker over the hosts in ~/.ssh/config.
--
-- leader R   (shift+r) lists every Host in ~/.ssh/config and the files it
--            Includes (patterns such as `*` or `*.lan` left out), its
--            HostName on the right. Hosts this ranma already has an ssh to
--            are marked ● and listed first. Enter goes to the pane already
--            connected there (in any session), or opens a workspace running
--            `ssh <host>`; ranma names the workspace after the destination.
--            With ssh.open = "pane", it splits the focused pane instead.
-- In the palette (leader :): `ssh [host]`, completing the hosts; with a
-- host, it goes there without a picker. `ssh !host` (or the picker's
-- second line for a connected host, `new`) opens another connection even
-- when one exists.
-- Another key: ranma.bind(KEY, function() ranma.emit("ssh") end), or with a
-- host as the data to go there.
--
-- A connection that fails leaves its pane up with ssh's exit status until
-- Enter, so the error can be read; one that ends normally closes it.
--
-- With ssh.badges on, a pane whose screen shows ssh giving up on a server
-- (`Timeout, server … not responding`, `client_loop: send disconnect`,
-- `Connection to … closed by remote host`, `Broken pipe`) gets a badge,
-- `✗ lost`, while ssh is still the pane's program (the same words printed
-- by anything else are not a loss). It goes when a command starts or
-- finishes there, when ssh is no longer in the foreground (seen on focus or
-- when the pane goes quiet), or when the pane closes. ServerAliveInterval in
-- the config is what makes ssh notice.
--
-- Which panes are connected where: the ssh processes whose RANMA_PANE is a
-- pane of this server, and their destination as typed (`ssh vps`, `ssh -p 22
-- me@vps`): read from /proc when the picker opens, never on a timer. Linux
-- only; elsewhere every host is listed as not connected.
--
-- Needs ranma 0.2.2 or newer.
--
-- ranma's plugin API: https://github.com/masshirodev/ranma/blob/main/doc/CONFIG.md ("Pickers and
-- prompts", "Pane handles", "Timers and processes", "Hooks").

ranma.option("ssh.config", {
  type = "string", default = "~/.ssh/config",
  name = "Config file", desc = "The ssh config to read hosts from; its Include lines are followed.",
})
ranma.option("ssh.open", {
  type = "enum", choices = { "workspace", "pane" }, default = "workspace",
  name = "Open in", desc = "A new connection opens in an empty workspace, or in a pane split from the focused one.",
})
ranma.option("ssh.badges", {
  type = "bool", default = true,
  name = "Lost badge", desc = "Mark a pane whose screen shows ssh losing its server.",
})

local HOME = os.getenv("HOME") or ""

local function fail(err)
  ranma.toast("ssh: " .. tostring(err), { urgent = true })
end

local function untilde(path)
  if path == "~" or path:sub(1, 2) == "~/" then return HOME .. path:sub(2) end
  return path
end

local function read(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local text = f:read("a")
  f:close()
  return text
end

local function sh(word)
  return "'" .. word:gsub("'", "'\\''") .. "'"
end

-- The config -------------------------------------------------------------------

local function is_pattern(name)
  return name:find("[%*%?!]") ~= nil
end

-- A config line's keyword and its arguments, quotes honoured.
local function words(line)
  local out = {}
  local rest = line
  while true do
    rest = rest:gsub("^%s+", "")
    if rest == "" then break end
    local q = rest:match('^"([^"]*)"')
    if q then
      out[#out + 1] = q
      rest = rest:sub(#q + 3)
    else
      local w = rest:match("^[^%s]+")
      out[#out + 1] = w
      rest = rest:sub(#w + 1)
    end
  end
  -- `Key=value` is allowed as well as `Key value`.
  if out[1] and out[1]:find("=", 1, true) then
    local k, v = out[1]:match("^([^=]*)=(.*)$")
    out[1] = k
    if v ~= "" then table.insert(out, 2, v) end
  elseif out[2] == "=" then
    table.remove(out, 2)
  end
  return out
end

local function include_patterns(text)
  local out = {}
  for line in (text .. "\n"):gmatch("(.-)\r?\n") do
    local w = words((line:gsub("#.*$", "")))
    if w[1] and w[1]:lower() == "include" then
      for i = 2, #w do
        local p = untilde(w[i])
        if p:sub(1, 1) ~= "/" then p = HOME .. "/.ssh/" .. p end
        out[#out + 1] = p
      end
    end
  end
  return out
end

-- Every Host, in the order ssh reads them: done({ { name, hostname, user,
-- port }, ... }). An Include is read where it stands, as ssh does, so the
-- first value given for a host wins across files too. Globs go through the
-- shell: first every Include pattern is expanded (one spawn per level of
-- nesting), then the files are read in order.
local function hosts(done)
  local expanded = {}   -- pattern -> files
  local function resolve(patterns, depth, next)
    local todo = {}
    for _, p in ipairs(patterns) do
      if not expanded[p] then todo[#todo + 1] = p end
    end
    if #todo == 0 or depth > 8 then return next() end
    local argv = { "sh", "-c", 'for p in "$@"; do printf "\\036%s\\n" "$p"; for f in $p; do [ -f "$f" ] && printf "%s\\n" "$f"; done; done', "sh" }
    for _, p in ipairs(todo) do argv[#argv + 1] = p end
    ranma.spawn(argv, {
      timeout = 5,
      on_exit = function(r)
        local current, more = nil, {}
        for line in (r.stdout or ""):gmatch("[^\n]+") do
          if line:sub(1, 1) == "\30" then
            current = line:sub(2)
            expanded[current] = {}
          elseif current then
            table.insert(expanded[current], line)
            for _, q in ipairs(include_patterns(read(line) or "")) do more[#more + 1] = q end
          end
        end
        for _, p in ipairs(todo) do expanded[p] = expanded[p] or {} end
        resolve(more, depth + 1, next)
      end,
    })
  end

  local list, seen = {}, {}
  local block = {}
  local function parse(text, depth)
    for line in (text .. "\n"):gmatch("(.-)\r?\n") do
      local w = words((line:gsub("#.*$", "")))
      local key = w[1] and w[1]:lower()
      if key == "host" then
        block = {}
        for i = 2, #w do
          local name = w[i]
          if not is_pattern(name) then
            local h = seen[name]
            if not h then
              h = { name = name }
              seen[name] = h
              list[#list + 1] = h
            end
            block[#block + 1] = h
          end
        end
      elseif key == "match" then
        block = {}
      elseif key == "include" and depth < 8 then
        for i = 2, #w do
          local p = untilde(w[i])
          if p:sub(1, 1) ~= "/" then p = HOME .. "/.ssh/" .. p end
          for _, f in ipairs(expanded[p] or {}) do parse(read(f) or "", depth + 1) end
        end
      elseif key == "hostname" or key == "user" or key == "port" then
        for _, h in ipairs(block) do
          -- The first value given wins, as in ssh.
          if h[key] == nil then h[key] = w[2] end
        end
      end
    end
  end

  local main = read(untilde(ranma.get("ssh.config"))) or ""
  resolve(include_patterns(main), 0, function()
    parse(main, 0)
    done(list)
  end)
end

-- Connections ------------------------------------------------------------------

-- ssh's options that take an argument, so the destination is the first word
-- that is neither one of them nor an option's value.
local TAKES = {}
for c in ("BbcDEeFIiJLlmOoPpQRSWw"):gmatch(".") do TAKES[c] = true end

local function destination(args)
  local i = 2
  while i <= #args do
    local a = args[i]
    if a == "--" then return args[i + 1] end
    if a:sub(1, 1) == "-" and #a > 1 then
      -- -p22 carries its value; -p 22 does not; flags may be bundled (-tt).
      local last = a:sub(-1)
      local opt = a:sub(2, 2)
      if TAKES[opt] and #a == 2 then i = i + 1
      elseif TAKES[last] and #a > 2 and not TAKES[opt] then i = i + 1 end
    else
      return a
    end
    i = i + 1
  end
end

local function host_of(dest)
  if not dest then return nil end
  dest = dest:gsub("^ssh://", "")
  dest = dest:gsub("^.*@", "")
  dest = dest:gsub(":%d+$", "")
  return dest
end

local own_pid
local function me()
  if own_pid == nil then
    own_pid = tonumber((read("/proc/self/stat") or ""):match("^(%d+)")) or false
  end
  return own_pid or nil
end

-- done({ [host] = { pane, ... } }) for the ssh processes in this server's panes.
local function connections(done)
  local script = [[for p in $(pgrep -x ssh 2>/dev/null); do
  e=$(tr '\0' '\n' < /proc/$p/environ 2>/dev/null | grep -E '^RANMA(_PANE)?=' | tr '\n' ' ')
  [ -n "$e" ] || continue
  printf '%s\t' "$e"; tr '\0' '\037' < /proc/$p/cmdline; printf '\n'
done]]
  ranma.spawn({ "sh", "-c", script }, {
    timeout = 5,
    on_exit = function(r)
      local by = {}
      for line in (r.stdout or ""):gmatch("[^\n]+") do
        local env, cmd = line:match("^(.-)\t(.*)$")
        local server = env and tonumber(env:match("RANMA=(%d+)"))
        local pane = env and tonumber(env:match("RANMA_PANE=(%d+)"))
        -- A pane number of another live ranma server is not one of ours;
        -- after an upgrade the old pid is gone and the pane is ours.
        local other = server and me() and server ~= me()
          and (read("/proc/" .. server .. "/cmdline") or ""):find("ranma\0server", 1, true) ~= nil
        local p = pane and not other and ranma.pane(pane)
        if p then
          local args = {}
          for a in (cmd .. "\31"):gmatch("(.-)\31") do args[#args + 1] = a end
          local host = host_of(destination(args))
          if host then
            by[host] = by[host] or {}
            table.insert(by[host], p)
          end
        end
      end
      done(by)
    end,
  })
end

-- Opening ------------------------------------------------------------------------

local function free_workspace()
  local st = ranma.state()
  local taken = {}
  for _, n in ipairs(st.workspaces or {}) do taken[n] = true end
  for n in pairs(st.names or {}) do taken[n] = true end
  for _, n in ipairs(st.hidden or {}) do taken[n] = true end
  for n = 1, 99 do
    if not taken[n] then return tostring(n) end
  end
  return "empty"
end

local function connect(host)
  -- A failure keeps the pane, so ssh's message can be read.
  local line = "ssh -- " .. sh(host)
    .. [[ || { s=$?; printf '\nssh exited %s; Enter closes this pane. ' "$s"; read _; }]]
  if ranma.get("ssh.open") == "workspace" then
    ranma.action("workspace " .. free_workspace())
  end
  ranma.action("exec " .. line)
end

-- The pane to go to: one in the shown session, then a focused one.
local function best(panes)
  local session = ranma.state().session
  table.sort(panes, function(a, b)
    local sa = (a.session == session and 2 or 0) + (a.focused and 1 or 0)
    local sb = (b.session == session and 2 or 0) + (b.focused and 1 or 0)
    if sa ~= sb then return sa > sb end
    return a.id < b.id
  end)
  return panes[1]
end

local function go(host, by, fresh)
  local panes = by[host]
  if panes and #panes > 0 and not fresh then return best(panes):focus() end
  connect(host)
end

local listing = {}  -- names, for the palette's completion

local function open(arg)
  local fresh = false
  local name = arg and arg:match("^%s*(.-)%s*$") or ""
  if name:sub(1, 1) == "!" then
    fresh = true
    name = name:sub(2):gsub("^%s+", "")
  end
  hosts(function(list)
    listing = {}
    for _, h in ipairs(list) do listing[#listing + 1] = h.name end
    connections(function(by)
      if name ~= "" then return go(name, by, fresh) end
      if #list == 0 then return ranma.toast("ssh: no hosts in " .. ranma.get("ssh.config")) end
      local open_items, closed = {}, {}
      for _, h in ipairs(list) do
        local target = (h.user and h.user .. "@" or "") .. (h.hostname or h.name) .. (h.port and ":" .. h.port or "")
        local panes = by[h.name]
        if panes then
          local p = best(panes)
          local where = p.session .. ":" .. p.workspace
          open_items[#open_items + 1] = { label = h.name .. " ●", detail = where .. "  " .. target, host = h.name }
        else
          closed[#closed + 1] = { label = h.name, detail = target, host = h.name }
        end
      end
      for _, it in ipairs(closed) do open_items[#open_items + 1] = it end
      ranma.picker {
        title = "ssh",
        items = open_items,
        on_select = function(item)
          local panes = by[item.host]
          if panes and #panes > 0 then
            -- Connected: go there, or a second connection.
            return ranma.picker {
              title = "ssh · " .. item.host,
              items = {
                { label = "go", detail = "the pane connected there", fresh = false },
                { label = "new", detail = "another connection", fresh = true },
              },
              on_select = function(choice) go(item.host, by, choice.fresh) end,
            }
          end
          go(item.host, by, false)
        end,
      }
    end)
  end)
end

ranma.command("ssh", open, {
  desc = "a host from ~/.ssh/config: go to its connection, or open one",
  args = "[host]",
  complete = function()
    if #listing == 0 then pcall(hosts, function(list)
      for _, h in ipairs(list) do listing[#listing + 1] = h.name end
    end) end
    return listing
  end,
})
ranma.on("user:ssh", function(data) open(type(data) == "string" and data or nil) end)

-- WM mode ends as the picker opens: it has the keyboard from there.
ranma.bind("shift+r", function() open() end, { desc = "ssh hosts", group = "plugins", exit = true })

-- The lost badge ------------------------------------------------------------------

local LOST = {
  "Timeout, server .+ not responding",
  "client_loop: send disconnect",
  "Connection to .+ closed by remote host",
  "packet_write_wait: .*Broken pipe",
  "Write failed: Broken pipe",
}

local watches = {}   -- pane id -> watch ids
local lost = {}      -- pane id -> true

local function clear(id)
  if not lost[id] then return end
  lost[id] = nil
  local p = ranma.pane(id)
  if p then p:badge("ssh") end
end

local SSH = { ssh = true, autossh = true, ["mosh-client"] = true }

local function on_ssh(p)
  return p and SSH[p:program() or ""] or false
end

local function watch(p)
  if watches[p.id] or not ranma.get("ssh.badges") then return end
  local ids = {}
  for _, pattern in ipairs(LOST) do
    ids[#ids + 1] = p:watch(pattern, function(ev)
      local q = ranma.pane(ev.pane)
      -- The same words printed by anything else (a log, this README) are not a loss.
      if not on_ssh(q) then return end
      lost[ev.pane] = true
      q:badge("ssh", "✗", "lost", "urgent")
    end)
  end
  watches[p.id] = ids
end

-- Panes already open (a reload) are watched once loading is over: handles
-- only exist at run time.
ranma.defer(0, function()
  for _, p in ipairs(ranma.panes()) do watch(p) end
end)
ranma.on("pane_open", function(ev)
  local p = ranma.pane(ev.pane)
  if p then watch(p) end
end)
ranma.on("pane_close", function(ev)
  for _, id in ipairs(watches[ev.pane] or {}) do ranma.unwatch(id) end
  watches[ev.pane] = nil
  lost[ev.pane] = nil
end)
ranma.on("command_started", function(ev) clear(ev.pane) end)
ranma.on("command_finished", function(ev) clear(ev.pane) end)
-- Without the shell's marks there are no command events: ssh no longer in
-- the foreground is the end of it too.
local function settle(id)
  if lost[id] and not on_ssh(ranma.pane(id)) then clear(id) end
end
ranma.on("focus_change", function(ev) settle(ev.pane) end)
ranma.on("pane_idle", function(ev) settle(ev.pane) end)
