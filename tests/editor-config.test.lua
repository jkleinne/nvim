-- Tests for the editor settings that keep repo code from running and tools from phoning home
-- (lua/plugins/lsp.lua with its gates in lua/lsp_gates/, lua/plugins/lint.lua, lua/plugins/conform.lua,
-- lua/settings.lua):
-- nvim --clean --headless -l tests/editor-config.test.lua
--
-- Hermetic: XDG_STATE_HOME, XDG_DATA_HOME, and XDG_CACHE_HOME point at a scratch dir (removed at the
-- end) before anything calls stdpath, so the real trust database and data dirs are never read or
-- written; setting them inside this nvim is enough, because stdpath reads the environment on each
-- call (checked below before any test runs). The plugins are stub modules in package.loaded; the gate
-- modules are the real ones. The cases that depend on which commands exist set PATH to scratch dirs of
-- stub commands (they exit 1 and no test runs them); the other cases run no command. Every case
-- starts with Arch's TypeScript path (lsp_gates.typescript.ARCH_TSSERVER) pointing at a missing
-- scratch path, and the TypeScript cases point it at a scratch package instead. The trust cases use
-- the real vim.secure functions on the scratch trust database. Stubbed per case and restored after
-- it: nvim_list_uis, vim.notify, vim.fn.confirm (a trust prompt is recorded and cancelled, so it never
-- waits for input), vim.secure.read (wrapped to record its calls), vim.lsp.enable and
-- vim.cmd.doautoall (recorded instead of run in the :TerraformTrust cases), and HOME (L10c). Nothing
-- is installed or downloaded, and no language server starts. Exits nonzero when a test fails.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:gsub("^@", ""), ":p:h:h")
local tmp = vim.fn.tempname()
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
  list_uis = vim.api.nvim_list_uis,
  secure_read = vim.secure.read,
  notify = vim.notify,
}

-- The system servers and their commands, as lua/plugins/lsp.lua sets them
local system_cmds = {
  bashls = { "bash-language-server", "start" },
  dockerls = { "docker-langserver", "--stdio" },
  jsonls = { "vscode-json-language-server", "--stdio" },
  pyright = { "pyright-langserver", "--stdio" },
  ts_ls = { "typescript-language-server", "--stdio" },
  yamlls = { "yaml-language-server", "--stdio" },
}
local server_names = vim.tbl_keys(system_cmds)
table.sort(server_names)
local server_bins = {}
for _, name in ipairs(server_names) do
  server_bins[#server_bins + 1] = system_cmds[name][1]
end
-- Every config a case can enable or change
local lsp_names = vim.list_extend({ "terraformls" }, server_names)

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

local mason_setup_opts

local function stub_plugins()
  mason_setup_opts = nil
  package.loaded["blink.cmp"] = {
    get_lsp_capabilities = function()
      return {}
    end,
  }
  package.loaded["mason-lspconfig"] = {
    setup = function(opts)
      mason_setup_opts = opts
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

-- A UI (or none), the real vim.secure.read wrapped to record its calls, a vim.fn.confirm that
-- records a trust prompt and cancels it, and a vim.notify that records. Calls, prompts, and notices
-- go to one ordered event list.
local function stub_trust(has_ui)
  local events = {}
  vim.api.nvim_list_uis = function()
    return has_ui and { {} } or {}
  end
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
    want(problems, not vim.lsp.is_enabled "ts_ls", "ts_ls enabled")
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
  vim.api.nvim_list_uis = original.list_uis
  vim.secure.read = original.secure_read
  vim.notify = original.notify
  vim.lsp.enable(lsp_names, false)
  for _, name in ipairs(vim.list_extend({ "*", "lua_ls" }, lsp_names)) do
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
-- servers and a leftover Mason copy of a retired one never starts
case("L1-mason-list", function()
  local want_exclude =
    vim.list_extend({ "ansiblels", "docker_compose_language_service", "docker_language_server", "sqlls" }, server_names)
  table.sort(want_exclude)
  local problems = {}
  vim.env.PATH = bins.none
  for _, present in ipairs { true, false } do
    arch_typescript(present)
    load_spec "lsp"
    local label = present and "with TypeScript: " or "without TypeScript: "
    local opts = mason_setup_opts or {}
    want(
      problems,
      vim.deep_equal(opts.ensure_installed, { "gopls", "lua_ls", "sqls", "terraformls" }),
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
-- so a manual :lsp enable never falls back to lspconfig's node_modules/.bin lookup; none is enabled
case("L2b-cmd-pinned-when-absent", function()
  vim.env.PATH = bins.none
  load_spec "lsp"
  local problems = {}
  for _, name in ipairs(server_names) do
    want(problems, not vim.lsp.is_enabled(name), name .. " enabled")
    local cmd = (vim.lsp.config[name] or {}).cmd
    want(problems, vim.deep_equal(cmd, system_cmds[name]), name .. " cmd " .. show(cmd))
  end
  return joined(problems)
end)

-- L3: with none of them on PATH (the TypeScript requirement met), none is enabled
case("L3-system-servers-absent", function()
  vim.env.PATH = bins.none
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
  return ts_ls_problems(vim.uv.fs_realpath(typescript_tsserver_js))
end)

-- With a TypeScript package's tsserver on PATH as well, Arch's TypeScript wins
case("L4d-arch", function()
  vim.env.PATH = bins.servers .. ":" .. typescript_link_dir
  arch_typescript(true)
  load_spec "lsp"
  return ts_ls_problems(arch_present)
end)

-- L4e: without a system TypeScript, ts_ls's root_dir never hands Neovim a root, so not even a manual
-- :lsp enable starts it with the workspace's TypeScript. With one, lsp.lua sets no root_dir
-- (lspconfig's applies).
case("L4e-ts_ls-refuses-without-typescript", function()
  vim.env.PATH = bins.servers
  arch_typescript(false)
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
-- without asking, even with no UI
case("L7-terraformls-no-cli", function()
  vim.env.PATH = bins.none
  local events = stub_trust(false)
  load_spec "lsp"
  local dir, buf = project "L7"
  local dirs = root_dirs(vim.lsp.config.terraformls.root_dir, buf)
  local problems = {}
  want(problems, vim.deep_equal(dirs, { dir }), "on_dir calls " .. show(dirs))
  want(problems, #events == 0, "events " .. show(events))
  return joined(problems)
end)

-- L8 to L11b: with the CLI (and a UI that could show a prompt), only the trust database decides,
-- read by lsp.lua's gate alone: no case calls vim.secure.read (it would prompt for an unanswered
-- root, and a second reader could disagree with the gate). L8: a root the database does not answer
-- never starts and is never asked about; one INFO notice names the root and :TerraformTrust instead
case("L8-unanswered-no-prompt", function()
  vim.env.PATH = bins.terraform
  local events = stub_trust(true)
  load_spec "lsp"
  local dir, buf = project "L8"
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

-- The notice shows once per root per session
case("L9a-notice-once", function()
  vim.env.PATH = bins.terraform
  local events = stub_trust(true)
  load_spec "lsp"
  local dir, buf = project "L9a"
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
  vim.env.PATH = bins.terraform
  local events = stub_trust(true)
  load_spec "lsp"
  local dir, buf = project "L9b"
  trust("allow", dir)
  local dirs = root_dirs(vim.lsp.config.terraformls.root_dir, buf)
  local problems = {}
  want(problems, #events == 0, "events " .. show(events))
  want(problems, vim.deep_equal(dirs, { dir }), "on_dir calls " .. show(dirs))
  return joined(problems)
end)

-- A denied root never starts, and gets no vim.secure.read call, prompt, or notice
case("L9c-denied", function()
  vim.env.PATH = bins.terraform
  local events = stub_trust(true)
  load_spec "lsp"
  local dir, buf = project "L9c"
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
  vim.env.PATH = bins.terraform
  local events = stub_trust(true)
  load_spec "lsp"
  local dir, buf = project "L9d"
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
  vim.env.PATH = bins.terraform
  local events = stub_trust(true)
  local spec = load_spec "lsp"
  local dir, buf = project "L9e"
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
  vim.env.PATH = bins.terraform
  local events = stub_trust(true)
  load_spec "lsp"
  local dir, buf = project "L9f"
  write_trust { string.rep("0123456789abcdef", 4) .. " " .. vim.uv.fs_realpath(dir) }
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
  vim.env.PATH = bins.terraform
  local events = stub_trust(true)
  load_spec "lsp"
  local dir, buf = project "L9g"
  local real = vim.uv.fs_realpath(dir)
  write_trust { "directory " .. real, "! " .. real }
  local denied = root_dirs(vim.lsp.config.terraformls.root_dir, buf)
  write_trust { "! " .. real, "directory " .. real }
  local allowed = root_dirs(vim.lsp.config.terraformls.root_dir, buf)
  local problems = {}
  want(problems, #denied == 0, "directory then !: on_dir calls " .. show(denied))
  want(problems, vim.deep_equal(allowed, { dir }), "! then directory: on_dir calls " .. show(allowed))
  want(problems, #events == 0, "events " .. show(events))
  return joined(problems)
end)

-- L10: :TerraformTrust allows the current buffer's root in the trust database and, with terraformls
-- enabled, re-runs its gate for open buffers through vim.lsp.enable (never through doautoall on
-- Neovim's internal augroup), so terraform-ls starts there
case("L10-terraform-trust-command", function()
  vim.env.PATH = bins.terraform
  stub_trust(true)
  load_spec "lsp"
  local dir, buf = project "L10"
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
  want(problems, vim.deep_equal(lines, { "directory " .. vim.uv.fs_realpath(dir) }), "trust database " .. show(lines))
  want(problems, vim.deep_equal(calls, { { "enable", "terraformls" } }), "activation calls " .. show(calls))
  local dirs = root_dirs(vim.lsp.config.terraformls.root_dir, buf)
  want(problems, vim.deep_equal(dirs, { dir }), "on_dir calls after the command " .. show(dirs))
  return joined(problems)
end)

-- Problems unless events is exactly one WARN notice that points at :trust, and the trust database
-- and activation calls are empty
local function refused_problems(label, events, calls)
  local problems = {}
  local notice = events[1] or {}
  want(
    problems,
    #events == 1 and notice[3] == vim.log.levels.WARN and tostring(notice[2]):find(":trust", 1, true) ~= nil,
    label .. ": want one WARN notice naming :trust; got " .. show(events)
  )
  want(problems, #trust_lines() == 0, label .. ": trust database " .. show(trust_lines()))
  want(problems, #calls == 0, label .. ": activation calls " .. show(calls))
  return problems
end

-- L10b: from a buffer with a 'buftype' (here nofile) :TerraformTrust refuses: vim.fs.root would
-- start from the cwd, so the root would not be this file's
case("L10b-terraform-trust-nofile", function()
  vim.env.PATH = bins.terraform
  local events = stub_trust(true)
  load_spec "lsp"
  local dir = project "L10b"
  vim.fn.mkdir(vim.fn.stdpath "state", "p")
  local buf = nofile_buffer(dir)
  vim.api.nvim_set_current_buf(buf)
  local calls = record_activation()
  vim.cmd "TerraformTrust"
  local problems = {}
  local notice = events[1] or {}
  want(problems, #events == 1 and notice[3] == vim.log.levels.WARN, "want one WARN notice; got " .. show(events))
  want(problems, #trust_lines() == 0, "trust database " .. show(trust_lines()))
  want(problems, #calls == 0, "activation calls " .. show(calls))
  return joined(problems)
end)

-- L10c: :TerraformTrust refuses roots where trust would cover far more than one project: /, the
-- home directory, and a world-writable directory (:trust <dir> still allows them on purpose)
case("L10c-terraform-trust-broad-roots", function()
  vim.env.PATH = bins.terraform
  local events = stub_trust(true)
  load_spec "lsp"
  vim.fn.mkdir(vim.fn.stdpath "state", "p")
  local home, home_buf = project "L10c-home"
  vim.env.HOME = home
  local open, open_buf = project "L10c-world-writable"
  assert(vim.uv.fs_chmod(open, tonumber("777", 8)))
  local targets = { { "home", home_buf }, { "world-writable", open_buf } }
  -- A file directly under /: its root is / unless / has a .terraform or .git
  if not vim.uv.fs_stat "/.terraform" and not vim.uv.fs_stat "/.git" then
    targets[#targets + 1] = { "/", vim.fn.bufadd "/editor-config-test-L10c.tf" }
  end
  local calls = record_activation()
  local problems = {}
  for _, target in ipairs(targets) do
    vim.api.nvim_set_current_buf(target[2])
    local before = #events
    vim.cmd "TerraformTrust"
    vim.list_extend(problems, refused_problems(target[1], vim.list_slice(events, before + 1), calls))
  end
  return joined(problems)
end)

-- L10d: with terraformls not enabled yet (mason-lspconfig enables it once installed), :TerraformTrust
-- still writes the database, without error and without enabling anything
case("L10d-terraform-trust-not-enabled", function()
  vim.env.PATH = bins.terraform
  stub_trust(true)
  load_spec "lsp"
  local dir, buf = project "L10d"
  vim.fn.mkdir(vim.fn.stdpath "state", "p")
  vim.api.nvim_set_current_buf(buf)
  local calls = record_activation()
  local ok, err = pcall(vim.cmd, "TerraformTrust")
  local problems = {}
  want(problems, ok, "error " .. tostring(err))
  local lines = trust_lines()
  want(problems, vim.deep_equal(lines, { "directory " .. vim.uv.fs_realpath(dir) }), "trust database " .. show(lines))
  want(problems, #calls == 0, "activation calls " .. show(calls))
  return joined(problems)
end)

-- L11: an unnamed buffer has no root, so it never starts terraform-ls or asks about the cwd
case("L11-unnamed-buffer", function()
  vim.env.PATH = bins.terraform
  local events = stub_trust(true)
  load_spec "lsp"
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
  vim.env.PATH = bins.terraform
  local events = stub_trust(true)
  load_spec "lsp"
  local dirs = root_dirs(vim.lsp.config.terraformls.root_dir, nofile_buffer(project "L11b"))
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
  vim.env.PATH = bins.none
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
  vim.env.PATH = bins.none
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
  vim.env.PATH = bins.none
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

-- L15: terraform runs started from Neovim skip HashiCorp's update check. Last, because settings.lua
-- sets global options and autocmds that later cases would inherit.
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
