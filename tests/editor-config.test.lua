-- Tests for the editor settings that keep repo code from running and tools from phoning home
-- (lua/plugins/lsp.lua, lua/plugins/lint.lua, lua/plugins/conform.lua, lua/settings.lua):
-- nvim --clean --headless -l tests/editor-config.test.lua
--
-- Hermetic: XDG_STATE_HOME, XDG_DATA_HOME, and XDG_CACHE_HOME point at a scratch dir (removed at the
-- end) before anything calls stdpath, so the real trust database and data dirs are never read or
-- written; setting them inside this nvim is enough, because stdpath reads the environment on each
-- call (checked below before any test runs). The plugins are stub modules in package.loaded, PATH
-- holds only scratch dirs of stub commands (they exit 1 and no test runs them), and the trust cases
-- use the real vim.secure functions on the scratch trust database. Stubbed per case and restored
-- after it: nvim_list_uis, vim.notify, vim.fn.confirm (a trust prompt is recorded and cancelled, so
-- it never waits for input), vim.secure.read (wrapped to record its calls), vim.cmd.doautoall (L10),
-- and fs_stat and readfile for Arch's TypeScript package only. Nothing is installed or downloaded,
-- and no language server starts. Exits nonzero when a test fails.

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
  fs_stat = vim.uv.fs_stat,
  readfile = vim.fn.readfile,
  confirm = vim.fn.confirm,
  doautoall = vim.cmd.doautoall,
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

-- A scratch TypeScript package (package.json, lib/tsserver.js, bin/tsserver) and a dir whose
-- tsserver links to the package's bin script, the way npm links a global package's command.
-- Returns that dir (for PATH) and the package's lib/tsserver.js.
local function typescript_package()
  local package_root = tmp .. "/tspkg/node_modules/typescript"
  vim.fn.mkdir(package_root .. "/lib", "p")
  vim.fn.mkdir(package_root .. "/bin", "p")
  vim.fn.writefile({ typescript_package_json }, package_root .. "/package.json")
  vim.fn.writefile({}, package_root .. "/lib/tsserver.js")
  vim.fn.writefile({ "#!/bin/sh", "exit 1" }, package_root .. "/bin/tsserver")
  assert(vim.uv.fs_chmod(package_root .. "/bin/tsserver", tonumber("755", 8)))
  local link_dir = bin_dir("tsserver-link", {})
  assert(vim.uv.fs_symlink(package_root .. "/bin/tsserver", link_dir .. "/tsserver"))
  return link_dir, package_root .. "/lib/tsserver.js"
end
local typescript_link_dir, typescript_tsserver_js = typescript_package()

local arch_tsserver = "/usr/lib/node_modules/typescript/lib/tsserver.js"
local arch_package_json = "/usr/lib/node_modules/typescript/package.json"

-- Makes Arch's TypeScript package (its tsserver.js and package.json) present or absent; every other
-- path goes to the real fs_stat and readfile
local function stub_arch_tsserver(present)
  vim.uv.fs_stat = function(path, ...)
    if path == arch_tsserver or path == arch_package_json then
      if present then
        return { type = "file" }
      end
      return nil, "ENOENT: stubbed absent: " .. path, "ENOENT"
    end
    return original.fs_stat(path, ...)
  end
  vim.fn.readfile = function(path, ...)
    if path == arch_package_json then
      assert(present, "read the stubbed-absent " .. path)
      return { typescript_package_json }
    end
    return original.readfile(path, ...)
  end
end

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

local function trust_file()
  return vim.fn.stdpath "state" .. "/trust"
end

-- Answers dir in the scratch trust database with the real vim.secure.trust, as :trust does
local function trust(action, dir)
  vim.fn.mkdir(vim.fn.stdpath "state", "p")
  local ok, message = vim.secure.trust { action = action, path = dir }
  assert(ok, message)
end

-- A scratch project dir with a .git dir and an (unloaded) buffer for its main.tf
local function project(name)
  local dir = tmp .. "/project-" .. name
  vim.fn.mkdir(dir .. "/.git", "p")
  vim.fn.writefile({}, dir .. "/main.tf")
  return dir, vim.fn.bufadd(dir .. "/main.tf")
end

-- Whether event is the INFO notice that names dir and :TerraformTrust
local function is_trust_notice(event, dir)
  return event ~= nil
    and event[1] == "notify"
    and event[3] == vim.log.levels.INFO
    and event[2]:find(dir, 1, true) ~= nil
    and event[2]:find(":TerraformTrust", 1, true) ~= nil
end

-- Calls a terraformls root_dir function and returns the dirs it passed to on_dir
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
  vim.uv.fs_stat = original.fs_stat
  vim.fn.readfile = original.readfile
  vim.fn.confirm = original.confirm
  vim.cmd.doautoall = original.doautoall
  vim.api.nvim_list_uis = original.list_uis
  vim.secure.read = original.secure_read
  vim.notify = original.notify
  vim.lsp.enable(server_names, false)
  for _, name in ipairs(vim.list_extend({ "*", "lua_ls", "terraformls" }, server_names)) do
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
-- docker_language_server (with or without a system TypeScript), so only lsp.lua's gates start them
case("L1-mason-list", function()
  local want_exclude = vim.list_extend({ "docker_language_server" }, server_names)
  table.sort(want_exclude)
  local problems = {}
  vim.env.PATH = bins.none
  for _, typescript in ipairs { true, false } do
    stub_arch_tsserver(typescript)
    load_spec "lsp"
    local label = typescript and "with TypeScript: " or "without TypeScript: "
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
  stub_arch_tsserver(true)
  load_spec "lsp"
  local problems = {}
  for _, name in ipairs(server_names) do
    want(problems, vim.lsp.is_enabled(name), name .. " not enabled")
    local cmd = (vim.lsp.config[name] or {}).cmd
    want(problems, vim.deep_equal(cmd, system_cmds[name]), name .. " cmd " .. show(cmd))
  end
  return joined(problems)
end)

-- L3: with none of them on PATH (the TypeScript requirement met), none is enabled
case("L3-system-servers-absent", function()
  vim.env.PATH = bins.none
  stub_arch_tsserver(true)
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
  stub_arch_tsserver(false)
  load_spec "lsp"
  return ts_ls_problems(nil)
end)

-- A tsserver on PATH that belongs to no TypeScript package does not count
case("L4b-shim-rejected", function()
  vim.env.PATH = bins.servers_tsserver
  stub_arch_tsserver(false)
  load_spec "lsp"
  return ts_ls_problems(nil)
end)

-- A tsserver on PATH that links into a TypeScript package counts: ts_ls gets that package's
-- lib/tsserver.js
case("L4c-package-tsserver", function()
  vim.env.PATH = bins.servers .. ":" .. typescript_link_dir
  stub_arch_tsserver(false)
  load_spec "lsp"
  return ts_ls_problems(vim.uv.fs_realpath(typescript_tsserver_js))
end)

-- With a TypeScript package's tsserver on PATH as well, Arch's TypeScript wins
case("L4d-arch", function()
  vim.env.PATH = bins.servers .. ":" .. typescript_link_dir
  stub_arch_tsserver(true)
  load_spec "lsp"
  return ts_ls_problems(arch_tsserver)
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

-- L8 to L11: with the CLI (and a UI that could show a prompt), only the trust database decides.
-- L8: a root it does not answer never starts and is never asked about (vim.secure.read would
-- prompt); one INFO notice names the root and :TerraformTrust instead
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

-- An allowed root (:TerraformTrust or :trust) starts it; vim.secure.read decides without a prompt
case("L9b-allowed", function()
  vim.env.PATH = bins.terraform
  local events = stub_trust(true)
  load_spec "lsp"
  local dir, buf = project "L9b"
  trust("allow", dir)
  local dirs = root_dirs(vim.lsp.config.terraformls.root_dir, buf)
  local problems = {}
  want(
    problems,
    vim.deep_equal(events, { { "read", dir } }),
    "want only vim.secure.read(" .. dir .. "); got " .. show(events)
  )
  want(problems, vim.deep_equal(dirs, { dir }), "on_dir calls " .. show(dirs))
  return joined(problems)
end)

-- A denied root never starts, and gets neither a prompt nor a notice
case("L9c-denied", function()
  vim.env.PATH = bins.terraform
  local events = stub_trust(true)
  load_spec "lsp"
  local dir, buf = project "L9c"
  trust("deny", dir)
  local dirs = root_dirs(vim.lsp.config.terraformls.root_dir, buf)
  local problems = {}
  want(
    problems,
    vim.deep_equal(events, { { "read", dir } }),
    "want only vim.secure.read(" .. dir .. "); got " .. show(events)
  )
  want(problems, #dirs == 0, "on_dir calls " .. show(dirs))
  return joined(problems)
end)

-- An allowed root is checked on every start, so `:trust ++remove` takes effect without a restart
case("L9d-allow-rechecked", function()
  vim.env.PATH = bins.terraform
  local events = stub_trust(true)
  load_spec "lsp"
  local dir, buf = project "L9d"
  trust("allow", dir)
  local dirs = root_dirs(vim.lsp.config.terraformls.root_dir, buf)
  vim.list_extend(dirs, root_dirs(vim.lsp.config.terraformls.root_dir, buf))
  local problems = {}
  want(
    problems,
    vim.deep_equal(events, { { "read", dir }, { "read", dir } }),
    "want two vim.secure.read calls; got " .. show(events)
  )
  want(problems, vim.deep_equal(dirs, { dir, dir }), "on_dir calls " .. show(dirs))
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

-- L10: :TerraformTrust allows the current buffer's root in the trust database and re-runs the
-- FileType pass of vim.lsp.enable, so terraform-ls starts there
case("L10-terraform-trust-command", function()
  vim.env.PATH = bins.terraform
  stub_trust(true)
  load_spec "lsp"
  local dir, buf = project "L10"
  local autocmds = {}
  vim.cmd.doautoall = function(arg)
    autocmds[#autocmds + 1] = arg
  end
  vim.api.nvim_set_current_buf(buf)
  vim.cmd "TerraformTrust"
  local problems = {}
  local lines = vim.fn.filereadable(trust_file()) == 1 and vim.fn.readfile(trust_file()) or {}
  local want_lines = { "directory " .. vim.uv.fs_realpath(dir) }
  want(problems, vim.deep_equal(lines, want_lines), "trust database " .. show(lines))
  want(problems, vim.deep_equal(autocmds, { "nvim.lsp.enable FileType" }), "doautoall calls " .. show(autocmds))
  local dirs = root_dirs(vim.lsp.config.terraformls.root_dir, buf)
  want(problems, vim.deep_equal(dirs, { dir }), "on_dir calls after the command " .. show(dirs))
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

-- L12: conform runs the system prettier, never a repo's node_modules copy
case("L12-prettier-pinned", function()
  local spec = dofile(root .. "/lua/plugins/conform.lua")
  local command = vim.tbl_get(spec, "opts", "formatters", "prettier", "command")
  if command ~= "prettier" then
    return "prettier command " .. show(command)
  end
end)

-- L13: yamlls never downloads schemas: the schema stores are off, and on_init (which keeps
-- lspconfig's formatting line) has the server send $schema URLs to Neovim
case("L13-yamlls-no-downloads", function()
  vim.env.PATH = bins.none
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
  local notifications = {}
  local client = {
    server_capabilities = {},
    notify = function(_, method)
      notifications[#notifications + 1] = method
    end,
  }
  if type(config.on_init) ~= "function" then
    want(problems, false, "on_init " .. show(config.on_init))
  else
    config.on_init(client, {})
  end
  want(
    problems,
    client.server_capabilities.documentFormattingProvider == true,
    "documentFormattingProvider " .. show(client.server_capabilities.documentFormattingProvider)
  )
  want(
    problems,
    vim.deep_equal(notifications, { "yaml/registerContentRequest" }),
    "notifications " .. show(notifications)
  )
  return joined(problems)
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
