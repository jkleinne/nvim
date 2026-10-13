-- Tests for the editor settings that keep repo code from running and tools from phoning home
-- (lua/plugins/lsp.lua with its server list and gates in lua/lsp_gates/, lua/plugins/lint.lua,
-- lua/plugins/conform.lua, lua/settings.lua):
-- nvim --clean --headless -l tests/editor-config.test.lua
--
-- Hermetic: XDG_STATE_HOME, XDG_DATA_HOME, and XDG_CACHE_HOME point at a scratch dir (removed at the
-- end) before anything calls stdpath, so the real trust database and data dirs are never read or
-- written; setting them inside this nvim is enough, because stdpath reads the environment on each
-- call (checked below before any test runs). The scratch dir is a resolved path: Neovim resolves
-- symlinks in buffer names, and TMPDIR may be a symlink. The plugins are stub modules in
-- package.loaded; the lsp_gates modules are the real ones. Every case starts with PATH set to an
-- empty scratch dir and Arch's TypeScript path (lsp_gates.typescript.ARCH_TSSERVER) pointing at a
-- missing scratch path; the cases that depend on which commands exist set PATH to scratch dirs of
-- stub commands (they exit 1 and no test runs them), and the TypeScript cases point ARCH_TSSERVER at
-- a scratch package. The trust cases use the real vim.secure functions on the scratch trust
-- database. Stubbed per case and restored after it: vim.notify, vim.fn.confirm (a trust prompt is
-- recorded and cancelled, so it never waits for input), vim.secure.read (wrapped to record its
-- calls), vim.lsp.enable and vim.cmd.doautoall (recorded instead of run in the :TerraformTrust
-- cases), lsp_gates.terraform_trust.trust_hash (L10f), vim.uv.getuid (L8b, L10c), and HOME; L10g
-- wraps vim.lsp's functions around one call and restores them itself. Nothing is installed or
-- downloaded, and no language server starts. Exits nonzero when a test fails.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:gsub("^@", ""), ":p:h:h")
-- Resolved before any path is built from it, so those paths match the (resolved) buffer names
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
tmp = assert(vim.uv.fs_realpath(tmp))
vim.env.XDG_STATE_HOME = tmp .. "/state"
vim.env.XDG_DATA_HOME = tmp .. "/data"
vim.env.XDG_CACHE_HOME = tmp .. "/cache"
for _, kind in ipairs { "state", "data", "cache" } do
  if not vim.startswith(vim.fn.stdpath(kind), tmp .. "/") then
    io.write(
      ("FAIL setup: stdpath(%q) is %s, not under %s; stopping\nexit=1\n"):format(kind, vim.fn.stdpath(kind), tmp)
    )
    vim.cmd.cquit { count = 1 }
  end
end

-- lsp.lua requires its gates from lua/lsp_gates/, and --clean leaves this config off 'runtimepath'
package.path = root .. "/lua/?.lua;" .. package.path
local typescript = require "lsp_gates.typescript"
local terraform_trust = require "lsp_gates.terraform_trust"

-- No swap files ('directory' still names the real state dir), and the startup buffer is not a file
-- buffer, so the FileType pass in vim.lsp.enable() never starts a server for it
vim.o.swapfile = false
local startup_buf = vim.api.nvim_get_current_buf()
vim.bo[startup_buf].buftype = "nofile"

local failed = 0

-- One result line; print() in -l mode defers the newline to the next message
local function say(line)
  io.write(line, "\n")
end

local function show(value)
  return vim.inspect(value, { newline = " ", indent = "" })
end

-- Records a problem unless ok holds
local function want(problems, ok, message)
  if not ok then
    problems[#problems + 1] = "[" .. message .. "]"
  end
end

local function joined(problems)
  if #problems > 0 then
    return table.concat(problems, " ")
  end
end

-- ---------------------------------------------------------------------------
-- Stubs
-- ---------------------------------------------------------------------------

local original = {
  path = vim.env.PATH,
  home = vim.env.HOME,
  arch_tsserver = typescript.ARCH_TSSERVER,
  confirm = vim.fn.confirm,
  doautoall = vim.cmd.doautoall,
  lsp_enable = vim.lsp.enable,
  secure_read = vim.secure.read,
  notify = vim.notify,
  trust_hash = terraform_trust.trust_hash,
  getuid = vim.uv.getuid,
}

-- The server inventory, as lua/lsp_gates/servers.lua holds it. An independent copy: L1b checks that
-- lsp.lua takes its lists from the module, and the other cases check lsp.lua against this copy.
local mason_names = { "gopls", "lua_ls", "sqls", "terraformls" }
local system_cmds = {
  bashls = { "bash-language-server", "start" },
  dockerls = { "docker-langserver", "--stdio" },
  jsonls = { "vscode-json-language-server", "--stdio" },
  pyright = { "pyright-langserver", "--stdio" },
  ts_ls = { "typescript-language-server", "--stdio" },
  yamlls = { "yaml-language-server", "--stdio" },
}
local retired_names = { "ansiblels", "docker_compose_language_service", "docker_language_server", "sqlls" }
local server_names = vim.tbl_keys(system_cmds)
table.sort(server_names)
local server_bins = {}
for _, name in ipairs(server_names) do
  server_bins[#server_bins + 1] = system_cmds[name][1]
end
-- Every config a case can enable or change
local lsp_names = vim.list_extend(vim.list_extend({ "lua_ls", "terraformls" }, server_names), retired_names)

-- A scratch dir holding a stub executable for each command, for use as the whole PATH
local function bin_dir(name, commands)
  local dir = tmp .. "/bin-" .. name
  vim.fn.mkdir(dir, "p")
  for _, command in ipairs(commands) do
    local f = assert(io.open(dir .. "/" .. command, "w"))
    f:write "#!/bin/sh\nexit 1\n"
    f:close()
    assert(vim.uv.fs_chmod(dir .. "/" .. command, tonumber("755", 8)))
  end
  return dir
end
local bins = {
  none = bin_dir("none", {}),
  servers = bin_dir("servers", server_bins),
  -- Three of the six: bashls, ts_ls, and yamlls
  some_servers = bin_dir("some-servers", { system_cmds.bashls[1], system_cmds.ts_ls[1], system_cmds.yamlls[1] }),
  -- tsserver here is a wrapper script that belongs to no TypeScript package, like a version
  -- manager's shim
  servers_tsserver = bin_dir("servers-tsserver", vim.list_extend({ "tsserver" }, server_bins)),
  terraform = bin_dir("terraform", { "terraform" }),
}

local typescript_package_json = '{"name":"typescript","version":"5.0.0"}'

-- A scratch package at <tmp>/<name>/node_modules/typescript with this package.json, an empty
-- lib/tsserver.js, and an executable bin/tsserver. Returns its lib/tsserver.js.
local function fake_package(name, package_json)
  local package_root = tmp .. "/" .. name .. "/node_modules/typescript"
  vim.fn.mkdir(package_root .. "/lib", "p")
  vim.fn.mkdir(package_root .. "/bin", "p")
  vim.fn.writefile({ package_json }, package_root .. "/package.json")
  vim.fn.writefile({}, package_root .. "/lib/tsserver.js")
  vim.fn.writefile({ "#!/bin/sh", "exit 1" }, package_root .. "/bin/tsserver")
  assert(vim.uv.fs_chmod(package_root .. "/bin/tsserver", tonumber("755", 8)))
  return package_root .. "/lib/tsserver.js"
end

-- Stand-ins for Arch's TypeScript package: a scratch package, and a path where there is none
local arch_present = fake_package("arch", typescript_package_json)
local arch_missing = tmp .. "/arch-missing/node_modules/typescript/lib/tsserver.js"

-- Makes Arch's TypeScript package present or absent
local function arch_typescript(present)
  typescript.ARCH_TSSERVER = present and arch_present or arch_missing
end

-- Another TypeScript package, and a dir whose tsserver links to the package's bin script, the way
-- npm links a global package's command (for PATH)
local typescript_tsserver_js = fake_package("tspkg", typescript_package_json)
local typescript_link_dir = bin_dir("tsserver-link", {})
assert(
  vim.uv.fs_symlink(
    vim.fs.dirname(vim.fs.dirname(typescript_tsserver_js)) .. "/bin/tsserver",
    typescript_link_dir .. "/tsserver"
  )
)

-- The settings that must be in place when mason-lspconfig.setup runs: it enables the Mason servers,
-- which re-fires FileType for open buffers. Each is { label, getter }.
local before_setup = {
  {
    "terraformls root_dir",
    function()
      return (vim.lsp.config.terraformls or {}).root_dir
    end,
  },
  {
    "ts_ls root_dir",
    function()
      return (vim.lsp.config.ts_ls or {}).root_dir
    end,
  },
  {
    "lua_ls window/showMessageRequest handler",
    function()
      return vim.tbl_get(vim.lsp.config.lua_ls or {}, "handlers", "window/showMessageRequest")
    end,
  },
}
for _, name in ipairs(retired_names) do
  before_setup[#before_setup + 1] = {
    name .. " root_dir",
    function()
      return (vim.lsp.config[name] or {}).root_dir
    end,
  }
end

-- What mason-lspconfig.setup got, and the before_setup values when it ran (index-aligned)
local mason_setup_opts, setup_time_values

local function stub_plugins()
  mason_setup_opts, setup_time_values = nil, nil
  package.loaded["blink.cmp"] = {
    get_lsp_capabilities = function()
      return {}
    end,
  }
  package.loaded["mason-lspconfig"] = {
    setup = function(opts)
      mason_setup_opts = opts
      setup_time_values = {}
      for i, setting in ipairs(before_setup) do
        setup_time_values[i] = setting[2]()
      end
    end,
  }
  package.loaded["lint"] = { linters = {}, try_lint = function() end }
  package.loaded["lint.linters.tflint"] = { cmd = "tflint", args = { "--format=json", "--recursive" } }
  package.loaded["lint.linters.golangcilint"] = { cmd = "golangci-lint", args = { "run", "--output.json.path=stdout" } }
end

-- A fresh copy of the spec (fresh file-level state) with its config() run
local function load_spec(name)
  stub_plugins()
  local spec = dofile(root .. "/lua/plugins/" .. name .. ".lua")
  spec.config()
  return spec
end

-- The real vim.secure.read wrapped to record its calls, a vim.fn.confirm that records a trust prompt
-- and cancels it, and a vim.notify that records. Calls, prompts, and notices go to one ordered event
-- list.
local function record_events()
  local events = {}
  vim.secure.read = function(path)
    events[#events + 1] = { "read", path }
    return original.secure_read(path)
  end
  vim.fn.confirm = function(msg)
    events[#events + 1] = { "prompt", msg }
    return 0
  end
  vim.notify = function(msg, level)
    events[#events + 1] = { "notify", msg, level }
  end
  return events
end

-- Records vim.lsp.enable and vim.cmd.doautoall calls instead of running them
local function record_activation()
  local calls = {}
  vim.lsp.enable = function(...)
    calls[#calls + 1] = { "enable", ... }
  end
  vim.cmd.doautoall = function(...)
    calls[#calls + 1] = { "doautoall", ... }
  end
  return calls
end

local function trust_file()
  return vim.fn.stdpath "state" .. "/trust"
end

local function trust_lines()
  return vim.fn.filereadable(trust_file()) == 1 and vim.fn.readfile(trust_file()) or {}
end

-- Answers dir in the scratch trust database with the real vim.secure.trust, as :trust does
local function trust(action, dir)
  vim.fn.mkdir(vim.fn.stdpath "state", "p")
  local ok, message = vim.secure.trust { action = action, path = dir }
  assert(ok, message)
end

-- Writes the scratch trust database by hand (for lines vim.secure.trust never writes)
local function write_trust(lines)
  vim.fn.mkdir(vim.fn.stdpath "state", "p")
  vim.fn.writefile(lines, trust_file())
end

-- A scratch project dir with a .git dir and an (unloaded) buffer for its main.tf
local function project(name)
  local dir = tmp .. "/project-" .. name
  vim.fn.mkdir(dir .. "/.git", "p")
  vim.fn.writefile({}, dir .. "/main.tf")
  return dir, vim.fn.bufadd(dir .. "/main.tf")
end

-- The start of the cases with the terraform CLI: PATH holds only terraform, events are recorded,
-- lsp.lua's config() has run, and there is a project. Returns the events, the project dir, its
-- main.tf buffer, and the spec.
local function terraform_setup(name)
  vim.env.PATH = bins.terraform
  local events = record_events()
  local spec = load_spec "lsp"
  local dir, buf = project(name)
  return events, dir, buf, spec
end

-- A loaded buffer for a file in dir with buftype=nofile
local function nofile_buffer(dir)
  local buf = vim.fn.bufadd(dir .. "/scratch.tf")
  vim.fn.bufload(buf)
  vim.bo[buf].buftype = "nofile"
  return buf
end

-- Whether event is the INFO notice that names dir and :TerraformTrust
local function is_trust_notice(event, dir)
  return event ~= nil
    and event[1] == "notify"
    and event[3] == vim.log.levels.INFO
    and event[2]:find(dir, 1, true) ~= nil
    and event[2]:find(":TerraformTrust", 1, true) ~= nil
end

-- Calls a root_dir function and returns the dirs it passed to on_dir
local function root_dirs(root_dir, buf)
  local dirs = {}
  root_dir(buf, function(dir)
    dirs[#dirs + 1] = dir
  end)
  return dirs
end

-- Problems unless ts_ls is enabled with tsserver_path as its TypeScript, or (tsserver_path nil)
-- disabled with no TypeScript setting
local function ts_ls_problems(tsserver_path)
  local problems = {}
  local tsserver = vim.tbl_get(vim.lsp.config.ts_ls or {}, "init_options", "tsserver")
  if tsserver_path then
    want(problems, vim.lsp.is_enabled "ts_ls", "ts_ls not enabled")
    want(problems, vim.deep_equal(tsserver, { path = tsserver_path }), "tsserver " .. show(tsserver))
  else
    want(problems, not vim.lsp.is_enabled "ts_ls", "ts_ls not disabled")
    want(problems, tsserver == nil, "init_options.tsserver = " .. show(tsserver))
  end
  return joined(problems)
end

-- Undoes every stub and every LSP setting a case made
local function restore()
  vim.env.PATH = original.path
  vim.env.HOME = original.home
  typescript.ARCH_TSSERVER = original.arch_tsserver
  vim.fn.confirm = original.confirm
  vim.cmd.doautoall = original.doautoall
  vim.lsp.enable = original.lsp_enable
  vim.secure.read = original.secure_read
  vim.notify = original.notify
  terraform_trust.trust_hash = original.trust_hash
  vim.uv.getuid = original.getuid
  vim.lsp.enable(lsp_names, false)
  for _, name in ipairs(vim.list_extend({ "*" }, lsp_names)) do
    vim.lsp.config[name] = {}
  end
  vim.api.nvim_set_current_buf(startup_buf)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if buf ~= startup_buf then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  vim.fn.delete(trust_file())
end

-- Runs fn, which returns nil to pass or a string of problems, and prints the result line
local function case(id, fn)
  vim.env.PATH = bins.none
  arch_typescript(false)
  local ok, problems = pcall(fn)
  restore()
  if not ok then
    problems = "error: " .. tostring(problems)
  end
  if problems then
    say(("FAIL %s: %s"):format(id, problems))
    failed = 1
  else
    say("PASS " .. id)
  end
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

-- L1: Mason installs only the native servers, and its automatic enable skips the system servers and
-- the retired ones (with or without a system TypeScript), so only lsp.lua's gates start the system
-- servers and a leftover Mason copy of a retired one is never enabled automatically
case("L1-mason-list", function()
  local want_exclude = vim.list_extend(vim.deepcopy(retired_names), server_names)
  table.sort(want_exclude)
  local problems = {}
  for _, present in ipairs { true, false } do
    arch_typescript(present)
    load_spec "lsp"
    local label = present and "with TypeScript: " or "without TypeScript: "
    local opts = mason_setup_opts or {}
    want(
      problems,
      vim.deep_equal(opts.ensure_installed, mason_names),
      label .. "ensure_installed = " .. show(opts.ensure_installed)
    )
    want(
      problems,
      vim.deep_equal(vim.tbl_get(opts, "automatic_enable", "exclude"), want_exclude),
      label .. "automatic_enable = " .. show(opts.automatic_enable)
    )
  end
  return joined(problems)
end)

-- L1b: lsp.lua takes the server inventory from lua/lsp_gates/servers.lua (data only, also read by
-- the installer's tests): the module holds the inventory above, lsp.lua's Mason list, system
-- commands, and retired list equal it, and a different inventory in its place changes them
case("L1b-servers-module", function()
  local servers = require "lsp_gates.servers"
  local problems = {}
  want(problems, vim.deep_equal(servers.mason, mason_names), "module mason " .. show(servers.mason))
  want(problems, vim.deep_equal(servers.system, system_cmds), "module system " .. show(servers.system))
  want(problems, vim.deep_equal(servers.retired, retired_names), "module retired " .. show(servers.retired))

  -- Problems unless lsp.lua's lists (from its last config run) equal inventory
  local function lists_problems(label, inventory)
    local list_problems = {}
    local opts = mason_setup_opts or {}
    want(
      list_problems,
      vim.deep_equal(opts.ensure_installed, inventory.mason),
      label .. "ensure_installed " .. show(opts.ensure_installed)
    )
    local want_exclude = vim.list_extend(vim.tbl_keys(inventory.system), inventory.retired)
    table.sort(want_exclude)
    local exclude = vim.tbl_get(opts, "automatic_enable", "exclude")
    want(list_problems, vim.deep_equal(exclude, want_exclude), label .. "exclude " .. show(exclude))
    for _, name in ipairs(server_names) do
      local cmd = (vim.lsp.config[name] or {}).cmd
      want(list_problems, vim.deep_equal(cmd, inventory.system[name]), label .. name .. " cmd " .. show(cmd))
    end
    for _, name in ipairs(retired_names) do
      local root_dir = (vim.lsp.config[name] or {}).root_dir
      local retired = vim.list_contains(inventory.retired, name)
      want(
        list_problems,
        (type(root_dir) == "function") == retired,
        label .. name .. " root_dir " .. show(root_dir) .. (retired and " (retired)" or " (not retired)")
      )
    end
    return list_problems
  end

  load_spec "lsp"
  vim.list_extend(problems, lists_problems("", servers))

  restore()
  vim.env.PATH = bins.none
  arch_typescript(false)
  local other = {
    mason = { "gopls" },
    system = { bashls = { "other-bash-server", "start" } },
    retired = { "sqlls" },
  }
  package.loaded["lsp_gates.servers"] = other
  local ok, err = pcall(load_spec, "lsp")
  package.loaded["lsp_gates.servers"] = servers
  want(problems, ok, "config() with another inventory: " .. tostring(err))
  if ok then
    vim.list_extend(problems, lists_problems("another inventory: ", other))
  end
  return joined(problems)
end)

-- L1c: each retired server's root_dir never hands Neovim a root, so a leftover Mason copy never
-- starts, even when a bare :lsp enable (every config for the filetype) enables it
case("L1c-retired-refuse", function()
  load_spec "lsp"
  local _, buf = project "L1c"
  local problems = {}
  for _, name in ipairs(retired_names) do
    local root_dir = (vim.lsp.config[name] or {}).root_dir
    if type(root_dir) ~= "function" then
      want(problems, false, name .. " root_dir " .. show(root_dir))
    else
      local dirs = root_dirs(root_dir, buf)
      want(problems, #dirs == 0, name .. " on_dir calls " .. show(dirs))
    end
  end
  return joined(problems)
end)

-- L2: with every system command on PATH, each system server is enabled with its bare command
case("L2-system-servers-present", function()
  vim.env.PATH = bins.servers
  arch_typescript(true)
  load_spec "lsp"
  local problems = {}
  for _, name in ipairs(server_names) do
    want(problems, vim.lsp.is_enabled(name), name .. " not enabled")
    local cmd = (vim.lsp.config[name] or {}).cmd
    want(problems, vim.deep_equal(cmd, system_cmds[name]), name .. " cmd " .. show(cmd))
  end
  return joined(problems)
end)

-- L2b: with none of them on PATH (and no TypeScript), every system server still gets its list cmd,
-- so :lsp enable <name> never falls back to lspconfig's node_modules/.bin lookup; none is enabled
case("L2b-cmd-pinned-when-absent", function()
  load_spec "lsp"
  local problems = {}
  for _, name in ipairs(server_names) do
    want(problems, not vim.lsp.is_enabled(name), name .. " enabled")
    local cmd = (vim.lsp.config[name] or {}).cmd
    want(problems, vim.deep_equal(cmd, system_cmds[name]), name .. " cmd " .. show(cmd))
  end
  return joined(problems)
end)

-- L2c: with some of the commands on PATH, exactly those servers are enabled, ts_ls only with a
-- system TypeScript
case("L2c-only-present-servers-enabled", function()
  vim.env.PATH = bins.some_servers
  local problems = {}
  for _, present in ipairs { false, true } do
    arch_typescript(present)
    load_spec "lsp"
    local want_enabled = present and { "bashls", "ts_ls", "yamlls" } or { "bashls", "yamlls" }
    local enabled = vim.tbl_filter(vim.lsp.is_enabled, server_names)
    want(
      problems,
      vim.deep_equal(enabled, want_enabled),
      (present and "with" or "without") .. " TypeScript: enabled " .. show(enabled)
    )
    vim.lsp.enable(lsp_names, false)
  end
  return joined(problems)
end)

-- L2d: every setting a server needs before it can start is in place when mason-lspconfig.setup
-- enables the Mason servers (which re-fires FileType for open buffers): the mason-lspconfig stub
-- records them, and they already are the final values
case("L2d-config-before-setup", function()
  -- Without a system TypeScript, so ts_ls has a root_dir
  load_spec "lsp"
  local problems = {}
  if not setup_time_values then
    return "mason-lspconfig.setup never ran"
  end
  for i, setting in ipairs(before_setup) do
    local final = setting[2]()
    want(
      problems,
      type(final) == "function" and rawequal(setup_time_values[i], final),
      setting[1] .. ": at setup " .. show(setup_time_values[i]) .. ", final " .. show(final)
    )
  end
  return joined(problems)
end)

-- L3: with none of them on PATH (the TypeScript requirement met), none is enabled
case("L3-system-servers-absent", function()
  arch_typescript(true)
  load_spec "lsp"
  local enabled = vim.tbl_filter(vim.lsp.is_enabled, server_names)
  if #enabled > 0 then
    return "enabled: " .. table.concat(enabled, ", ")
  end
end)

-- L4: ts_ls needs a system TypeScript package, so it never loads a repo's node_modules/typescript
-- (typescript-language-server falls back to the workspace's TypeScript when tsserver.path is not a
-- TypeScript package's tsserver.js)
case("L4-ts_ls-fails-closed", function()
  vim.env.PATH = bins.servers
  arch_typescript(false)
  load_spec "lsp"
  return ts_ls_problems(nil)
end)

-- A tsserver on PATH that belongs to no TypeScript package does not count
case("L4b-shim-rejected", function()
  vim.env.PATH = bins.servers_tsserver
  arch_typescript(false)
  load_spec "lsp"
  return ts_ls_problems(nil)
end)

-- A tsserver on PATH that links into a TypeScript package counts: ts_ls gets that package's
-- lib/tsserver.js
case("L4c-package-tsserver", function()
  vim.env.PATH = bins.servers .. ":" .. typescript_link_dir
  arch_typescript(false)
  load_spec "lsp"
  return ts_ls_problems(typescript_tsserver_js)
end)

-- With a TypeScript package's tsserver on PATH as well, Arch's TypeScript wins
case("L4d-arch", function()
  vim.env.PATH = bins.servers .. ":" .. typescript_link_dir
  arch_typescript(true)
  load_spec "lsp"
  return ts_ls_problems(arch_present)
end)

-- L4e: without a system TypeScript, ts_ls's root_dir never hands Neovim a root, so not even
-- :lsp enable ts_ls starts it with the workspace's TypeScript. With one, lsp.lua sets no root_dir
-- (lspconfig's applies).
case("L4e-ts_ls-refuses-without-typescript", function()
  vim.env.PATH = bins.servers
  arch_typescript(false)
  record_events()
  load_spec "lsp"
  local root_dir = (vim.lsp.config.ts_ls or {}).root_dir
  if type(root_dir) ~= "function" then
    return "without TypeScript: root_dir " .. show(root_dir)
  end
  local problems = {}
  local dir = tmp .. "/project-L4e"
  vim.fn.mkdir(dir .. "/.git", "p")
  vim.fn.writefile({}, dir .. "/package-lock.json")
  vim.fn.writefile({}, dir .. "/index.ts")
  local dirs = root_dirs(root_dir, vim.fn.bufadd(dir .. "/index.ts"))
  want(problems, #dirs == 0, "without TypeScript: on_dir calls " .. show(dirs))
  vim.lsp.config.ts_ls = {}
  arch_typescript(true)
  load_spec "lsp"
  root_dir = (vim.lsp.config.ts_ls or {}).root_dir
  want(problems, root_dir == nil, "with TypeScript: root_dir " .. show(root_dir))
  return joined(problems)
end)

-- L4f: the package.json version must be a non-empty string: typescript-language-server treats a null
-- or "" version as invalid and falls back to the workspace's TypeScript
case("L4f-version-must-be-string", function()
  local problems = {}
  local valid = typescript.package_tsserver(typescript_tsserver_js)
  want(problems, valid == typescript_tsserver_js, "a valid package returned " .. show(valid))
  for _, version in ipairs { { "null", "null" }, { "empty", '""' } } do
    local js = fake_package("version-" .. version[1], '{"name":"typescript","version":' .. version[2] .. "}")
    local got = typescript.package_tsserver(js)
    want(problems, got == nil, version[1] .. " version accepted: " .. show(got))
  end
  return joined(problems)
end)

-- L4g: the package.json name must be typescript
case("L4g-name-must-be-typescript", function()
  local js = fake_package("not-typescript", '{"name":"not-typescript","version":"5.0.0"}')
  local got = typescript.package_tsserver(js)
  if got ~= nil then
    return "accepted: " .. show(got)
  end
end)

-- L4h: a package.json that is a directory or cannot be read makes no TypeScript package, without an
-- error (an error would stop lsp.lua's config)
case("L4h-package-json-unreadable", function()
  local problems = {}
  local dir_js = fake_package("json-dir", typescript_package_json)
  local dir_json = vim.fs.dirname(vim.fs.dirname(dir_js)) .. "/package.json"
  vim.fn.delete(dir_json)
  vim.fn.mkdir(dir_json, "p")
  local ok, got = pcall(typescript.package_tsserver, dir_js)
  want(problems, ok and got == nil, "package.json a directory: " .. (ok and "returned " or "error ") .. show(got))
  local unreadable_js = fake_package("json-unreadable", typescript_package_json)
  local unreadable_json = vim.fs.dirname(vim.fs.dirname(unreadable_js)) .. "/package.json"
  assert(vim.uv.fs_chmod(unreadable_json, 0))
  if vim.uv.fs_access(unreadable_json, "R") then
    say "SKIP L4h-package-json-unreadable unreadable file (mode 000 is still readable here, as for root)"
  else
    ok, got = pcall(typescript.package_tsserver, unreadable_js)
    want(problems, ok and got == nil, "package.json unreadable: " .. (ok and "returned " or "error ") .. show(got))
  end
  assert(vim.uv.fs_chmod(unreadable_json, tonumber("644", 8)))
  return joined(problems)
end)

-- L4i: ts_ls's refusing root_dir says why, once per session (a new config run starts a new one),
-- and never calls on_dir
case("L4i-ts_ls-refusal-notice", function()
  vim.env.PATH = bins.servers
  local events = record_events()
  local spec = load_spec "lsp"
  local root_dir = (vim.lsp.config.ts_ls or {}).root_dir
  if type(root_dir) ~= "function" then
    return "root_dir " .. show(root_dir)
  end
  local dir = tmp .. "/project-L4i"
  vim.fn.mkdir(dir .. "/.git", "p")
  vim.fn.writefile({}, dir .. "/index.ts")
  local buf = vim.fn.bufadd(dir .. "/index.ts")
  local dirs = root_dirs(root_dir, buf)
  vim.list_extend(dirs, root_dirs(root_dir, buf))
  local problems = {}
  want(problems, #dirs == 0, "on_dir calls " .. show(dirs))
  local function is_notice(event)
    return event ~= nil
      and event[1] == "notify"
      and event[3] == vim.log.levels.INFO
      and event[2]:find("ts_ls is off: no system TypeScript found", 1, true) ~= nil
  end
  want(problems, #events == 1 and is_notice(events[1]), "want one INFO notice over two calls; got " .. show(events))
  spec.config()
  root_dirs((vim.lsp.config.ts_ls or {}).root_dir, buf)
  want(problems, #events == 2 and is_notice(events[2]), "want a notice after config() again; got " .. show(events))
  return joined(problems)
end)

-- L4j: the check follows symlinks first, as typescript-language-server does: a tsserver.js that
-- links into a package that is not TypeScript does not count, even where the link's own
-- package.json says typescript
case("L4j-tsserver-symlink-resolved", function()
  local problems = {}
  local plain_js = fake_package("plain", '{"name":"not-typescript","version":"5.0.0"}')
  local decoy_js = fake_package("decoy", typescript_package_json)
  vim.fn.delete(decoy_js)
  assert(vim.uv.fs_symlink(plain_js, decoy_js))
  local got = typescript.package_tsserver(decoy_js)
  want(problems, got == nil, "link into a non-TypeScript package: " .. show(got))
  local link_js = tmp .. "/tsserver-link.js"
  assert(vim.uv.fs_symlink(typescript_tsserver_js, link_js))
  got = typescript.package_tsserver(link_js)
  want(problems, got == typescript_tsserver_js, "link into a TypeScript package: " .. show(got))
  return joined(problems)
end)

-- L5: tflint uses this config's tflint.hcl and a plugin dir under Neovim's data dir, keeps the rest
-- of the environment, and leaves nvim-lint's own definition unchanged
case("L5-tflint-pinned", function()
  local plugin_dir = vim.fn.stdpath "data" .. "/tflint-plugins"
  vim.fn.delete(plugin_dir, "rf")
  local problems = {}
  load_spec "lint"
  want(problems, vim.fn.isdirectory(plugin_dir) == 1, "config() did not create " .. plugin_dir)
  local want_args = { "--format=json", "--recursive", "--config=" .. vim.fn.stdpath "config" .. "/tflint.hcl" }
  local home = vim.fn.environ().HOME
  -- Twice: a second call must not see the first one's changes
  for call = 1, 2 do
    local linter = package.loaded.lint.linters.tflint()
    want(problems, vim.deep_equal(linter.args, want_args), "call " .. call .. " args " .. show(linter.args))
    local env = linter.env or {}
    want(
      problems,
      env.TFLINT_PLUGIN_DIR == plugin_dir,
      "call " .. call .. " TFLINT_PLUGIN_DIR " .. show(env.TFLINT_PLUGIN_DIR)
    )
    want(problems, home ~= nil and env.HOME == home, "call " .. call .. " HOME " .. show(env.HOME))
  end
  local stub_args = package.loaded["lint.linters.tflint"].args
  want(
    problems,
    vim.deep_equal(stub_args, { "--format=json", "--recursive" }),
    "module args changed: " .. show(stub_args)
  )
  return joined(problems)
end)

-- L6: golangci-lint ignores repo configs (a .golangci.yml can load a native plugin): --no-config
-- directly follows "run", and nvim-lint's own definition is unchanged
case("L6-golangci-no-config", function()
  load_spec "lint"
  local problems = {}
  local args = package.loaded.lint.linters.golangcilint().args or {}
  local run
  for i, arg in ipairs(args) do
    if arg == "run" then
      run = i
      break
    end
  end
  want(problems, run ~= nil and args[run + 1] == "--no-config", "--no-config does not follow run: " .. show(args))
  want(problems, vim.deep_equal(args, { "run", "--no-config", "--output.json.path=stdout" }), "args " .. show(args))
  local stub_args = package.loaded["lint.linters.golangcilint"].args
  want(
    problems,
    vim.deep_equal(stub_args, { "run", "--output.json.path=stdout" }),
    "module args changed: " .. show(stub_args)
  )
  return joined(problems)
end)

-- nvim-lint leaves args nil when `golangci-lint version` fails (not installed)
case("L6b-golangci-missing", function()
  load_spec "lint"
  package.loaded["lint.linters.golangcilint"] = { cmd = "golangci-lint", args = nil }
  local ok, linter = pcall(package.loaded.lint.linters.golangcilint)
  if not ok then
    return "error: " .. tostring(linter)
  end
  if linter.args ~= nil then
    return "args " .. show(linter.args)
  end
end)

-- Args without "run" get --no-config at the end (golangci-lint takes flags after the package path)
case("L6c-no-run", function()
  load_spec "lint"
  package.loaded["lint.linters.golangcilint"] =
    { cmd = "golangci-lint", args = { "--output.json.path=stdout", "/project" } }
  local args = package.loaded.lint.linters.golangcilint().args
  if not vim.deep_equal(args, { "--output.json.path=stdout", "/project", "--no-config" }) then
    return "args " .. show(args)
  end
end)

-- L7: without the terraform CLI nothing runs provider plugins, so terraform-ls starts at its root
-- without asking
case("L7-terraformls-no-cli", function()
  local events = record_events()
  load_spec "lsp"
  local dir, buf = project "L7"
  local dirs = root_dirs(vim.lsp.config.terraformls.root_dir, buf)
  local problems = {}
  want(problems, vim.deep_equal(dirs, { dir }), "on_dir calls " .. show(dirs))
  want(problems, #events == 0, "events " .. show(events))
  return joined(problems)
end)

-- L8 to L11b: with the CLI, only the trust database decides, read by the gate in
-- lua/lsp_gates/terraform_trust.lua alone: no case calls vim.secure.read (it would prompt for an
-- unanswered root, and a second reader could disagree with the gate). L8: a root the database does
-- not answer never starts and is never asked about; one INFO notice names the root and
-- :TerraformTrust instead
case("L8-unanswered-no-prompt", function()
  local events, dir, buf = terraform_setup "L8"
  local dirs = root_dirs(vim.lsp.config.terraformls.root_dir, buf)
  local problems = {}
  want(problems, #dirs == 0, "on_dir calls " .. show(dirs))
  want(
    problems,
    #events == 1 and is_trust_notice(events[1], dir),
    "want only an INFO notice naming " .. dir .. " and :TerraformTrust; got " .. show(events)
  )
  return joined(problems)
end)

-- L8b: the notice fits the root: one :TerraformTrust refuses (here the home directory) names :trust
-- for trusting it on purpose, one owned by another user says terraform-ls never starts there, and one
-- that does not exist yet (a new file in a new directory) says to save the file first
case("L8b-notice-variants", function()
  local events, home, home_buf = terraform_setup "L8b-home"
  vim.env.HOME = home
  local problems = {}

  -- Problems unless root_dir for buf gives no root and exactly one INFO notice containing each text
  local function notice_problems(label, buf, texts)
    local before = #events
    local dirs = root_dirs(vim.lsp.config.terraformls.root_dir, buf)
    local notices = vim.list_slice(events, before + 1)
    local notice = notices[1] or {}
    local ok = #notices == 1 and notice[1] == "notify" and notice[3] == vim.log.levels.INFO
    for _, text in ipairs(texts) do
      ok = ok and tostring(notice[2]):find(text, 1, true) ~= nil
    end
    want(problems, #dirs == 0, label .. ": on_dir calls " .. show(dirs))
    want(problems, ok, label .. ": want one INFO notice with " .. show(texts) .. "; got " .. show(notices))
  end

  notice_problems("home", home_buf, { home .. " (your home directory)", ":trust " .. home })

  local foreign, foreign_buf = project "L8b-foreign"
  local uid = original.getuid()
  vim.uv.getuid = function()
    return uid + 1
  end
  notice_problems(
    "foreign-owned",
    foreign_buf,
    { foreign .. " (owned by another user)", "only in directories you own" }
  )
  vim.uv.getuid = original.getuid
  local foreign_notice = tostring((events[#events] or {})[2])
  want(problems, foreign_notice:find(":trust", 1, true) == nil, "foreign-owned: notice names :trust")

  local missing = tmp .. "/L8b-missing"
  local missing_buf = vim.fn.bufadd(missing .. "/main.tf")
  local missing_root = terraform_trust.root(missing_buf)
  if missing_root ~= missing then
    say("SKIP L8b-notice-variants missing dir (its root is " .. show(missing_root) .. ", an existing ancestor)")
  else
    notice_problems("missing dir", missing_buf, { "save the file first", ":TerraformTrust" })
  end
  return joined(problems)
end)

-- The notice shows once per root per session
case("L9a-notice-once", function()
  local events, dir, buf = terraform_setup "L9a"
  local dirs = root_dirs(vim.lsp.config.terraformls.root_dir, buf)
  vim.list_extend(dirs, root_dirs(vim.lsp.config.terraformls.root_dir, buf))
  local problems = {}
  want(problems, #dirs == 0, "on_dir calls " .. show(dirs))
  want(
    problems,
    #events == 1 and is_trust_notice(events[1], dir),
    "want one notice over two calls; got " .. show(events)
  )
  return joined(problems)
end)

-- An allowed root (a directory line, as :TerraformTrust and :trust write) starts it, with no
-- vim.secure.read call, prompt, or notice
case("L9b-allowed", function()
  local events, dir, buf = terraform_setup "L9b"
  trust("allow", dir)
  local dirs = root_dirs(vim.lsp.config.terraformls.root_dir, buf)
  local problems = {}
  want(problems, #events == 0, "events " .. show(events))
  want(problems, vim.deep_equal(dirs, { dir }), "on_dir calls " .. show(dirs))
  return joined(problems)
end)

-- A denied root never starts, and gets no vim.secure.read call, prompt, or notice
case("L9c-denied", function()
  local events, dir, buf = terraform_setup "L9c"
  trust("deny", dir)
  local dirs = root_dirs(vim.lsp.config.terraformls.root_dir, buf)
  local problems = {}
  want(problems, #events == 0, "events " .. show(events))
  want(problems, #dirs == 0, "on_dir calls " .. show(dirs))
  return joined(problems)
end)

-- The database is read on every start, so `:trust ++remove` takes effect without a restart: the
-- removed root is unanswered again (no start, one notice)
case("L9d-allow-rechecked", function()
  local events, dir, buf = terraform_setup "L9d"
  trust("allow", dir)
  local dirs = root_dirs(vim.lsp.config.terraformls.root_dir, buf)
  vim.list_extend(dirs, root_dirs(vim.lsp.config.terraformls.root_dir, buf))
  trust("remove", dir)
  local after_remove = root_dirs(vim.lsp.config.terraformls.root_dir, buf)
  local problems = {}
  want(problems, vim.deep_equal(dirs, { dir, dir }), "on_dir calls while allowed " .. show(dirs))
  want(problems, #after_remove == 0, "on_dir calls after the removal " .. show(after_remove))
  want(
    problems,
    #events == 1 and is_trust_notice(events[1], dir),
    "want only the notice after the removal; got " .. show(events)
  )
  return joined(problems)
end)

-- Running config() again (for example :Lazy reload) starts a new session of notices
case("L9e-config-resets-notice", function()
  local events, dir, buf, spec = terraform_setup "L9e"
  root_dirs(vim.lsp.config.terraformls.root_dir, buf)
  spec.config()
  root_dirs(vim.lsp.config.terraformls.root_dir, buf)
  if not (#events == 2 and is_trust_notice(events[1], dir) and is_trust_notice(events[2], dir)) then
    return "want a notice before and after config(); got " .. show(events)
  end
end)

-- A line for the root with a file's content hash (neither "directory" nor "!") does not allow it,
-- and the root gets the notice. vim.secure.trust writes only "directory" or "!" for a directory, so
-- the line is written by hand.
case("L9f-stale-hash-unanswered", function()
  local events, dir, buf = terraform_setup "L9f"
  write_trust { string.rep("0123456789abcdef", 4) .. " " .. dir }
  local dirs = root_dirs(vim.lsp.config.terraformls.root_dir, buf)
  local problems = {}
  want(problems, #dirs == 0, "on_dir calls " .. show(dirs))
  want(
    problems,
    #events == 1 and is_trust_notice(events[1], dir),
    "want only an INFO notice naming " .. dir .. " and :TerraformTrust; got " .. show(events)
  )
  return joined(problems)
end)

-- The last line for a path wins, as in Neovim's own reader (runtime secure.lua): "directory" then
-- "!" is denied, "!" then "directory" is allowed
case("L9g-last-line-wins", function()
  local events, dir, buf = terraform_setup "L9g"
  write_trust { "directory " .. dir, "! " .. dir }
  local denied = root_dirs(vim.lsp.config.terraformls.root_dir, buf)
  write_trust { "! " .. dir, "directory " .. dir }
  local allowed = root_dirs(vim.lsp.config.terraformls.root_dir, buf)
  local problems = {}
  want(problems, #denied == 0, "directory then !: on_dir calls " .. show(denied))
  want(problems, vim.deep_equal(allowed, { dir }), "! then directory: on_dir calls " .. show(allowed))
  want(problems, #events == 0, "events " .. show(events))
  return joined(problems)
end)

-- L9h: trust is keyed by the resolved path, as Neovim keys it: trusting a project through a symlink
-- allows it for buffers opened through either path (and the gate allows the link path too), while a
-- hand-written line for the unresolved link path alone allows neither
case("L9h-realpath-keying", function()
  local events, dir, buf = terraform_setup "L9h"
  local link = tmp .. "/L9h-link"
  assert(vim.uv.fs_symlink(dir, link))
  local link_buf = vim.fn.bufadd(link .. "/main.tf")
  local problems = {}
  trust("allow", link)
  for _, opened in ipairs { { "real path", buf }, { "link path", link_buf } } do
    local dirs = root_dirs(vim.lsp.config.terraformls.root_dir, opened[2])
    want(
      problems,
      vim.deep_equal(dirs, { dir }),
      "trusted through the link, opened by " .. opened[1] .. ": " .. show(dirs)
    )
  end
  want(problems, terraform_trust.allowed(link), "trusted through the link: allowed(link) false")
  want(problems, terraform_trust.allowed(dir), "trusted through the link: allowed(dir) false")
  write_trust { "directory " .. link }
  want(problems, not terraform_trust.allowed(link), "unresolved link line: allowed(link) true")
  want(problems, not terraform_trust.allowed(dir), "unresolved link line: allowed(dir) true")
  local dirs = root_dirs(vim.lsp.config.terraformls.root_dir, link_buf)
  want(problems, #dirs == 0, "unresolved link line: on_dir calls " .. show(dirs))
  local asked = vim.tbl_filter(function(event)
    return event[1] ~= "notify"
  end, events)
  want(problems, #asked == 0, "reads or prompts " .. show(asked))
  return joined(problems)
end)

-- L9i: the root is the nearest ancestor with .terraform, else the nearest with .git (every ancestor
-- is searched for .terraform first), else the file's directory: a .terraform below .git wins, and so
-- does one above it. Checked without the CLI, where the gate hands Neovim the root.
case("L9i-root-rule", function()
  load_spec "lsp"
  local problems = {}
  local repo = tmp .. "/L9i-repo"
  vim.fn.mkdir(repo .. "/.git", "p")
  vim.fn.mkdir(repo .. "/env/.terraform", "p")
  vim.fn.writefile({}, repo .. "/env/main.tf")
  local dirs = root_dirs(vim.lsp.config.terraformls.root_dir, vim.fn.bufadd(repo .. "/env/main.tf"))
  want(problems, vim.deep_equal(dirs, { repo .. "/env" }), ".terraform below .git: on_dir calls " .. show(dirs))
  local outer = tmp .. "/L9i-outer"
  vim.fn.mkdir(outer .. "/.terraform", "p")
  vim.fn.mkdir(outer .. "/repo/.git", "p")
  vim.fn.writefile({}, outer .. "/repo/main.tf")
  dirs = root_dirs(vim.lsp.config.terraformls.root_dir, vim.fn.bufadd(outer .. "/repo/main.tf"))
  want(problems, vim.deep_equal(dirs, { outer }), ".terraform above .git: on_dir calls " .. show(dirs))
  return joined(problems)
end)

-- L9j: for every answered layout, Neovim's own reader (the real vim.secure.read, called directly)
-- agrees with the gate's trust_hash and never prompts: allowed reads as allowed, denied as denied
case("L9j-matches-neovim-reader", function()
  local events, dir = terraform_setup "L9j"
  local link = tmp .. "/L9j-link"
  assert(vim.uv.fs_symlink(dir, link))
  local layouts = {
    {
      "allow",
      function()
        trust("allow", dir)
      end,
      { dir },
    },
    {
      "deny",
      function()
        trust("deny", dir)
      end,
      { dir },
    },
    {
      "directory then !",
      function()
        write_trust { "directory " .. dir, "! " .. dir }
      end,
      { dir },
    },
    {
      "! then directory",
      function()
        write_trust { "! " .. dir, "directory " .. dir }
      end,
      { dir },
    },
    {
      "allowed through a symlink",
      function()
        trust("allow", link)
      end,
      { link, dir },
    },
  }
  local problems = {}
  for _, layout in ipairs(layouts) do
    vim.fn.delete(trust_file())
    layout[2]()
    for _, path in ipairs(layout[3]) do
      local read = original.secure_read(path)
      local hash = terraform_trust.trust_hash(path)
      want(
        problems,
        (read == true and hash == "directory") or (read == nil and hash == "!"),
        layout[1] .. ", " .. path .. ": vim.secure.read " .. show(read) .. ", trust_hash " .. show(hash)
      )
    end
  end
  want(problems, #events == 0, "events " .. show(events))
  return joined(problems)
end)

-- L10: :TerraformTrust allows the current buffer's root in the trust database and, with terraformls
-- enabled, re-runs its gate for open buffers through vim.lsp.enable (never through doautoall on
-- Neovim's internal augroup), so terraform-ls starts there
case("L10-terraform-trust-command", function()
  local _, dir, buf = terraform_setup "L10"
  vim.fn.mkdir(vim.fn.stdpath "state", "p")
  vim.api.nvim_set_current_buf(buf)
  -- Enabled, as mason-lspconfig leaves it; the filetypes keep its FileType pass off the empty main.tf
  -- (detected as "tf")
  vim.lsp.config("terraformls", { filetypes = { "terraform" } })
  vim.lsp.enable "terraformls"
  local calls = record_activation()
  vim.cmd "TerraformTrust"
  local problems = {}
  local lines = trust_lines()
  want(problems, vim.deep_equal(lines, { "directory " .. dir }), "trust database " .. show(lines))
  want(problems, vim.deep_equal(calls, { { "enable", "terraformls" } }), "activation calls " .. show(calls))
  local dirs = root_dirs(vim.lsp.config.terraformls.root_dir, buf)
  want(problems, vim.deep_equal(dirs, { dir }), "on_dir calls after the command " .. show(dirs))
  return joined(problems)
end)

-- Runs :TerraformTrust from buf with an empty trust database and fresh activation records. Problems
-- unless it gave exactly one WARN notice (whose text matches the Lua pattern, when one is given),
-- wrote nothing to the database, and activated nothing.
local function refused_problems(label, buf, events, pattern)
  vim.fn.delete(trust_file())
  vim.fn.mkdir(vim.fn.stdpath "state", "p")
  vim.api.nvim_set_current_buf(buf)
  local calls = record_activation()
  local before = #events
  vim.cmd "TerraformTrust"
  vim.lsp.enable = original.lsp_enable
  vim.cmd.doautoall = original.doautoall
  local notices = vim.list_slice(events, before + 1)
  local notice = notices[1] or {}
  local problems = {}
  want(
    problems,
    #notices == 1 and notice[3] == vim.log.levels.WARN and (pattern == nil or tostring(notice[2]):find(pattern) ~= nil),
    label .. ": want one WARN notice" .. (pattern and (" matching " .. pattern) or "") .. "; got " .. show(notices)
  )
  want(problems, #trust_lines() == 0, label .. ": trust database " .. show(trust_lines()))
  want(problems, #calls == 0, label .. ": activation calls " .. show(calls))
  return problems
end

-- L10b: from a buffer with a 'buftype' (here nofile) :TerraformTrust refuses: vim.fs.root would
-- start from the cwd, so the root would not be this file's
case("L10b-terraform-trust-nofile", function()
  local events, dir = terraform_setup "L10b"
  return joined(refused_problems("nofile", nofile_buffer(dir), events, "buffer that shows a file"))
end)

-- L10c: :TerraformTrust refuses roots where trust would cover far more than one project, or a
-- directory someone else controls, and names the reason: /, the home directory (also through a
-- symlinked HOME), a parent of it, a world-writable directory, and a directory owned by another
-- user. :trust <dir> still allows the first four on purpose, so their notice names it; the gate
-- never starts terraform-ls in a directory owned by another user, so that one says so instead.
case("L10c-terraform-trust-broad-roots", function()
  local events, home, home_buf = terraform_setup "L10c-home"
  local home_link = tmp .. "/L10c-home-link"
  assert(vim.uv.fs_symlink(home, home_link))
  local parent, parent_buf = project "L10c-parent"
  vim.fn.mkdir(parent .. "/home", "p")
  local open, open_buf = project "L10c-world-writable"
  assert(vim.uv.fs_chmod(open, tonumber("777", 8)))
  local _, foreign_buf = project "L10c-foreign"
  local uid = original.getuid()
  local function other_user()
    return uid + 1
  end
  local function names_trust(reason)
    return vim.pesc("(" .. reason .. ")") .. ".*:trust "
  end
  -- { label, buffer, HOME, notice pattern, getuid }
  local targets = {
    { "home", home_buf, home, names_trust "your home directory" },
    { "symlinked home", home_buf, home_link, names_trust "your home directory" },
    { "parent of home", parent_buf, parent .. "/home", names_trust "a parent of your home directory" },
    { "world-writable", open_buf, home, names_trust "world-writable" },
    {
      "foreign-owned",
      foreign_buf,
      home,
      vim.pesc "(owned by another user); terraform-ls starts only in directories you own" .. "$",
      other_user,
    },
  }
  -- A file directly under /: its root is / (with or without a .terraform or .git there)
  local slash_buf = vim.fn.bufadd "/editor-config-test-L10c.tf"
  local slash_root = terraform_trust.root(slash_buf)
  if slash_root == "/" then
    table.insert(targets, 1, { "/", slash_buf, home, names_trust "the filesystem root" })
  else
    say("SKIP L10c-terraform-trust-broad-roots / (the root of a file under / is " .. show(slash_root) .. ")")
  end
  local problems = {}
  for _, target in ipairs(targets) do
    vim.env.HOME = target[3]
    vim.uv.getuid = target[5] or original.getuid
    vim.list_extend(problems, refused_problems(target[1], target[2], events, target[4]))
    vim.uv.getuid = original.getuid
  end
  return joined(problems)
end)

-- L10d: with terraformls not enabled yet (mason-lspconfig enables it once installed), :TerraformTrust
-- still writes the database, without error and without enabling anything
case("L10d-terraform-trust-not-enabled", function()
  local _, dir, buf = terraform_setup "L10d"
  vim.fn.mkdir(vim.fn.stdpath "state", "p")
  vim.api.nvim_set_current_buf(buf)
  local calls = record_activation()
  local ok, err = pcall(vim.cmd, "TerraformTrust")
  local problems = {}
  want(problems, ok, "error " .. tostring(err))
  local lines = trust_lines()
  want(problems, vim.deep_equal(lines, { "directory " .. dir }), "trust database " .. show(lines))
  want(problems, #calls == 0, "activation calls " .. show(calls))
  return joined(problems)
end)

-- L10e: runtime secure.lua writes "<hash> <path>" lines without escaping, so trusting a directory
-- named "p\ndirectory <HOME>\nz" would add a line that trusts HOME. A root with a line break has
-- no root at all: :TerraformTrust refuses (one WARN, nothing written), the gate never allows it, and
-- HOME stays unanswered. A carriage return counts too.
case("L10e-newline-root", function()
  local events, home = terraform_setup "L10e-home"
  vim.env.HOME = home
  local injected = tmp .. "/p\ndirectory " .. home .. "\nz"
  vim.fn.mkdir(injected, "p")
  vim.fn.writefile({}, injected .. "/main.tf")
  local buf = vim.fn.bufadd(injected .. "/main.tf")
  local problems = refused_problems("newline root", buf, events, "buffer that shows a file")
  want(problems, terraform_trust.root(buf) == nil, "root " .. show(terraform_trust.root(buf)))
  want(problems, not terraform_trust.allowed(injected), "allowed(" .. show(injected) .. ")")
  want(problems, not terraform_trust.allowed(home), "allowed(HOME) after the command")
  local cr_dir = tmp .. "/cr\rdir"
  vim.fn.mkdir(cr_dir, "p")
  vim.fn.writefile({}, cr_dir .. "/main.tf")
  local cr_root = terraform_trust.root(vim.fn.bufadd(cr_dir .. "/main.tf"))
  want(problems, cr_root == nil, "carriage return: root " .. show(cr_root))
  want(problems, not terraform_trust.allowed(cr_dir), "carriage return: allowed")
  return joined(problems)
end)

-- L10f: :TerraformTrust checks that the gate reads back the entry it wrote: when it cannot (here
-- trust_hash answers nil once the database has a line), it warns, does not report success, and
-- does not re-run the gate
case("L10f-post-write-check", function()
  local events, _, buf = terraform_setup "L10f"
  vim.fn.mkdir(vim.fn.stdpath "state", "p")
  vim.api.nvim_set_current_buf(buf)
  vim.lsp.config("terraformls", { filetypes = { "terraform" } })
  vim.lsp.enable "terraformls"
  terraform_trust.trust_hash = function(path)
    if #trust_lines() > 0 then
      return nil
    end
    return original.trust_hash(path)
  end
  local calls = record_activation()
  vim.cmd "TerraformTrust"
  local problems = {}
  local notice = events[1] or {}
  want(
    problems,
    #events == 1
      and notice[3] == vim.log.levels.WARN
      and tostring(notice[2]):find("could not read it back", 1, true) ~= nil,
    "want one WARN notice that the entry could not be read back; got " .. show(events)
  )
  want(problems, #calls == 0, "activation calls " .. show(calls))
  return joined(problems)
end)

-- L10g: the command re-runs the gate (vim.lsp.enable) only when terraformls is enabled and a root
-- was trusted; trust_current_buffer itself returns the root and makes no vim.lsp call
case("L10g-command-reenables", function()
  local events, dir, buf = terraform_setup "L10g"
  local home = project "L10g-home"
  vim.fn.mkdir(vim.fn.stdpath "state", "p")
  vim.api.nvim_set_current_buf(buf)
  vim.lsp.config("terraformls", { filetypes = { "terraform" } })
  local problems = {}

  vim.lsp.enable "terraformls"
  local lsp_calls, saved = {}, {}
  for key, value in pairs(vim.lsp) do
    if type(value) == "function" then
      saved[key] = value
      vim.lsp[key] = function(...)
        lsp_calls[#lsp_calls + 1] = key
        return value(...)
      end
    end
  end
  local ok, got = pcall(terraform_trust.trust_current_buffer)
  for key, value in pairs(saved) do
    vim.lsp[key] = value
  end
  want(problems, ok and got == dir, "trust_current_buffer returned " .. show(got))
  want(problems, #lsp_calls == 0, "trust_current_buffer's vim.lsp calls " .. show(lsp_calls))

  -- { label, terraformls enabled, HOME, want a vim.lsp.enable call }
  for _, run in ipairs {
    { "enabled", true, home, true },
    { "not enabled", false, home, false },
    { "enabled, refused (home directory)", true, dir, false },
  } do
    vim.fn.delete(trust_file())
    vim.lsp.enable("terraformls", run[2])
    vim.env.HOME = run[3]
    local calls = record_activation()
    vim.cmd "TerraformTrust"
    vim.lsp.enable = original.lsp_enable
    vim.cmd.doautoall = original.doautoall
    local want_calls = run[4] and { { "enable", "terraformls" } } or {}
    want(problems, vim.deep_equal(calls, want_calls), run[1] .. ": activation calls " .. show(calls))
  end
  local asked = vim.tbl_filter(function(event)
    return event[1] ~= "notify"
  end, events)
  want(problems, #asked == 0, "reads or prompts " .. show(asked))
  return joined(problems)
end)

-- L11: an unnamed buffer has no root, so it never starts terraform-ls or asks about the cwd
case("L11-unnamed-buffer", function()
  local events = terraform_setup "L11"
  local buf = vim.api.nvim_create_buf(true, false)
  local dirs = root_dirs(vim.lsp.config.terraformls.root_dir, buf)
  local problems = {}
  want(problems, #dirs == 0, "on_dir calls " .. show(dirs))
  want(problems, #events == 0, "events " .. show(events))
  return joined(problems)
end)

-- L11b: neither has a buffer with a 'buftype' (here nofile), whose vim.fs.root would start from the
-- cwd
case("L11b-nofile-buffer", function()
  local events, dir = terraform_setup "L11b"
  local dirs = root_dirs(vim.lsp.config.terraformls.root_dir, nofile_buffer(dir))
  local problems = {}
  want(problems, #dirs == 0, "on_dir calls " .. show(dirs))
  want(problems, #events == 0, "events " .. show(events))
  return joined(problems)
end)

-- L12: conform runs the system prettier, never a repo's node_modules copy
case("L12-prettier-pinned", function()
  local spec = dofile(root .. "/lua/plugins/conform.lua")
  local command = vim.tbl_get(spec, "opts", "formatters", "prettier", "command")
  if command ~= "prettier" then
    return "prettier command " .. show(command)
  end
end)

-- A fake yamlls client whose notify calls go to notifications as { method, params }
local function yamlls_client(notifications)
  return {
    server_capabilities = {},
    notify = function(_, method, params)
      notifications[#notifications + 1] = { method, params }
    end,
  }
end

-- Problems unless notifications is exactly one yaml/registerContentRequest whose params encode as
-- an empty JSON object (yaml-language-server logs an ERROR for one without params)
local function content_request_problems(notifications)
  local problems = {}
  local methods = vim.tbl_map(function(n)
    return n[1]
  end, notifications)
  want(problems, vim.deep_equal(methods, { "yaml/registerContentRequest" }), "notifications " .. show(methods))
  local params = (notifications[1] or {})[2]
  local encoded = type(params) == "table" and vim.json.encode(params) or show(params)
  want(problems, encoded == "{}", "params " .. encoded)
  return problems
end

-- L13: yamlls never downloads schemas: the schema stores are off, and on_init has the server send
-- $schema URLs to Neovim. on_init chains the on_init configured before lsp.lua's (lspconfig's, which
-- turns on formatting) instead of replacing it.
case("L13-yamlls-no-downloads", function()
  local upstream_calls = {}
  vim.lsp.config("yamlls", {
    on_init = function(client, init_result)
      upstream_calls[#upstream_calls + 1] = { client, init_result }
      client.server_capabilities.documentFormattingProvider = true
    end,
  })
  load_spec "lsp"
  local config = vim.lsp.config.yamlls or {}
  local yaml = vim.tbl_get(config, "settings", "yaml") or {}
  local problems = {}
  want(problems, vim.tbl_get(yaml, "schemaStore", "enable") == false, "schemaStore " .. show(yaml.schemaStore))
  want(
    problems,
    vim.tbl_get(yaml, "kubernetesCRDStore", "enable") == false,
    "kubernetesCRDStore " .. show(yaml.kubernetesCRDStore)
  )
  if type(config.on_init) ~= "function" then
    want(problems, false, "on_init " .. show(config.on_init))
    return joined(problems)
  end
  local notifications = {}
  local client = yamlls_client(notifications)
  local init_result = {}
  config.on_init(client, init_result)
  want(
    problems,
    #upstream_calls == 1 and upstream_calls[1][1] == client and upstream_calls[1][2] == init_result,
    "upstream on_init calls " .. #upstream_calls
  )
  want(
    problems,
    client.server_capabilities.documentFormattingProvider == true,
    "documentFormattingProvider " .. show(client.server_capabilities.documentFormattingProvider)
  )
  vim.list_extend(problems, content_request_problems(notifications))
  return joined(problems)
end)

-- Without an earlier on_init (as under --clean, with no lspconfig), on_init still sends the request
case("L13b-yamlls-without-upstream", function()
  load_spec "lsp"
  local on_init = (vim.lsp.config.yamlls or {}).on_init
  if type(on_init) ~= "function" then
    return "on_init " .. show(on_init)
  end
  local notifications = {}
  on_init(yamlls_client(notifications), {})
  return joined(content_request_problems(notifications))
end)

-- L14: jsonls fetches only file: schemas itself; it sends http(s) $schema URLs to Neovim
case("L14-jsonls-no-downloads", function()
  load_spec "lsp"
  local protocols = vim.tbl_get(vim.lsp.config.jsonls or {}, "init_options", "handledSchemaProtocols")
  if not vim.deep_equal(protocols, { "file" }) then
    return "handledSchemaProtocols " .. show(protocols)
  end
end)

-- L16: tsserver's automatic type acquisition (npm installs of @types packages) is off, with and
-- without a system TypeScript
case("L16-ts_ls-no-type-acquisition", function()
  vim.env.PATH = bins.servers
  local problems = {}
  for _, present in ipairs { true, false } do
    vim.lsp.config.ts_ls = {}
    arch_typescript(present)
    load_spec "lsp"
    local ata = vim.tbl_get(vim.lsp.config.ts_ls or {}, "init_options", "disableAutomaticTypingAcquisition")
    want(
      problems,
      ata == true,
      (present and "with" or "without") .. " TypeScript: disableAutomaticTypingAcquisition " .. show(ata)
    )
  end
  return joined(problems)
end)

-- L17: lua_ls answers every window/showMessageRequest with null: LuaLS loads a repo's .luarc.json
-- runtime.plugin for either button of its trust prompt, so only a null answer declines it
case("L17-lua_ls-declines-prompts", function()
  load_spec "lsp"
  local handler = vim.tbl_get(vim.lsp.config.lua_ls or {}, "handlers", "window/showMessageRequest")
  if type(handler) ~= "function" then
    return "handler " .. show(handler)
  end
  local params =
    { type = 2, message = "Trust this workspace's plugin?", actions = { { title = "Yes" }, { title = "No" } } }
  local answer = handler(nil, params, { method = "window/showMessageRequest", client_id = 1 })
  if answer ~= vim.NIL then
    return "answer " .. show(answer)
  end
end)

-- L15: terraform runs started from Neovim skip HashiCorp's update check. It keeps its id from before
-- L16 and L17 but runs last, because settings.lua sets global options and autocmds that later cases
-- would inherit.
case("L15-checkpoint-disabled", function()
  vim.env.CHECKPOINT_DISABLE = nil
  dofile(root .. "/lua/settings.lua")
  if vim.env.CHECKPOINT_DISABLE ~= "1" then
    return "CHECKPOINT_DISABLE = " .. show(vim.env.CHECKPOINT_DISABLE)
  end
end)

vim.fn.delete(tmp, "rf")
say("exit=" .. failed)
io.flush()
-- :cquit rather than os.exit(), which skips Neovim's exit and leaves its temp dir behind
vim.cmd.cquit { count = failed }
