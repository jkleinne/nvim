-- Tests for the LSP and linter settings that keep repo code from running (lua/plugins/lsp.lua and
-- lua/plugins/lint.lua): nvim --clean --headless -l tests/editor-config.test.lua
--
-- Hermetic: XDG_STATE_HOME, XDG_DATA_HOME, and XDG_CACHE_HOME point at a scratch dir (removed at the
-- end) before anything calls stdpath, so the real trust database and data dirs are never read or
-- written; setting them inside this nvim is enough, because stdpath reads the environment on each
-- call (checked below before any test runs). The plugins are stub modules in package.loaded, PATH
-- holds only scratch dirs of stub commands (they exit 1 and no test runs them), and nvim_list_uis,
-- vim.secure.read, vim.notify, and fs_stat (for the Arch tsserver path only) are stubbed per case and
-- restored after it. Nothing is installed or downloaded, and no language server starts. Exits nonzero
-- when a test fails.

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
  servers_tsserver = bin_dir("servers-tsserver", vim.list_extend({ "tsserver" }, server_bins)),
  terraform = bin_dir("terraform", { "terraform" }),
}

local arch_tsserver = "/usr/lib/node_modules/typescript/lib/tsserver.js"

-- Makes the Arch tsserver path present or absent; every other path goes to the real fs_stat
local function stub_arch_tsserver(present)
  vim.uv.fs_stat = function(path, ...)
    if path == arch_tsserver then
      if present then
        return { type = "file" }
      end
      return nil, "ENOENT: stubbed absent: " .. path, "ENOENT"
    end
    return original.fs_stat(path, ...)
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

-- A UI (or none), a vim.secure.read that records its calls and returns the next scripted answer
-- ("allow" is true, anything else nil), and a vim.notify that records. Calls and notices go to one
-- ordered event list.
local function stub_trust(has_ui, answers)
  local events = {}
  vim.api.nvim_list_uis = function()
    return has_ui and { {} } or {}
  end
  vim.secure.read = function(path)
    events[#events + 1] = { "read", path }
    return table.remove(answers, 1) == "allow" or nil
  end
  vim.notify = function(msg, level)
    events[#events + 1] = { "notify", msg, level }
  end
  return events
end

-- A scratch project dir with a .git dir and an (unloaded) buffer for its main.tf
local function project(name)
  local dir = tmp .. "/project-" .. name
  vim.fn.mkdir(dir .. "/.git", "p")
  vim.fn.writefile({}, dir .. "/main.tf")
  return dir, vim.fn.bufadd(dir .. "/main.tf")
end

-- The vim.secure.read calls among the events
local function reads_of(events)
  return vim.tbl_filter(function(event)
    return event[1] == "read"
  end, events)
end

-- Calls a terraformls root_dir function and returns the dirs it passed to on_dir
local function root_dirs(root_dir, buf)
  local dirs = {}
  root_dir(buf, function(dir)
    dirs[#dirs + 1] = dir
  end)
  return dirs
end

local function trust_file()
  return vim.fn.stdpath "state" .. "/trust"
end

-- Undoes every stub and every LSP setting a case made
local function restore()
  vim.env.PATH = original.path
  vim.uv.fs_stat = original.fs_stat
  vim.api.nvim_list_uis = original.list_uis
  vim.secure.read = original.secure_read
  vim.notify = original.notify
  vim.lsp.enable(server_names, false)
  for _, name in ipairs(vim.list_extend({ "*", "lua_ls", "terraformls" }, server_names)) do
    vim.lsp.config[name] = {}
  end
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

-- L1: Mason installs only the native servers; docker-language-server is not one of them
case("L1-mason-list", function()
  vim.env.PATH = bins.none
  load_spec "lsp"
  local got = mason_setup_opts and mason_setup_opts.ensure_installed
  if not vim.deep_equal(got, { "gopls", "lua_ls", "sqls", "terraformls" }) then
    return "ensure_installed = " .. show(got)
  end
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

-- L4: ts_ls needs a system TypeScript (Arch's, else tsserver on PATH), so it never loads a repo's
-- node_modules/typescript
case("L4-ts_ls-fails-closed", function()
  vim.env.PATH = bins.servers
  stub_arch_tsserver(false)
  load_spec "lsp"
  local problems = {}
  want(problems, not vim.lsp.is_enabled "ts_ls", "ts_ls enabled")
  local init_options = (vim.lsp.config.ts_ls or {}).init_options or {}
  want(problems, init_options.tsserver == nil, "init_options.tsserver = " .. show(init_options.tsserver))
  return joined(problems)
end)

case("L4b-ts_ls-exepath", function()
  vim.env.PATH = bins.servers_tsserver
  stub_arch_tsserver(false)
  load_spec "lsp"
  local problems = {}
  want(problems, vim.lsp.is_enabled "ts_ls", "ts_ls not enabled")
  local tsserver = ((vim.lsp.config.ts_ls or {}).init_options or {}).tsserver
  want(
    problems,
    vim.deep_equal(tsserver, { path = bins.servers_tsserver .. "/tsserver" }),
    "tsserver " .. show(tsserver)
  )
  return joined(problems)
end)

-- With a tsserver on PATH as well, Arch's TypeScript wins
case("L4c-ts_ls-arch", function()
  vim.env.PATH = bins.servers_tsserver
  stub_arch_tsserver(true)
  load_spec "lsp"
  local problems = {}
  want(problems, vim.lsp.is_enabled "ts_ls", "ts_ls not enabled")
  local tsserver = ((vim.lsp.config.ts_ls or {}).init_options or {}).tsserver
  want(problems, vim.deep_equal(tsserver, { path = arch_tsserver }), "tsserver " .. show(tsserver))
  return joined(problems)
end)

-- L5: tflint uses this config's tflint.hcl and a plugin dir under Neovim's data dir, keeps the rest
-- of the environment, and leaves nvim-lint's own definition unchanged
case("L5-tflint-pinned", function()
  local plugin_dir = vim.fn.stdpath "data" .. "/tflint-plugins"
  local problems = {}
  want(problems, vim.fn.isdirectory(plugin_dir) == 0, plugin_dir .. " exists before config()")
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

-- L6: golangci-lint ignores repo configs (a .golangci.yml can load a native plugin)
case("L6-golangci-no-config", function()
  load_spec "lint"
  local problems = {}
  local linter = package.loaded.lint.linters.golangcilint()
  local want_args = { "run", "--no-config", "--output.json.path=stdout" }
  want(problems, vim.deep_equal(linter.args, want_args), "args " .. show(linter.args))
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

-- L7: without the terraform CLI nothing runs provider plugins, so terraform-ls starts at its root
-- without asking, even with no UI
case("L7-terraformls-no-cli", function()
  vim.env.PATH = bins.none
  local events = stub_trust(false, {})
  load_spec "lsp"
  local dir, buf = project "L7"
  local dirs = root_dirs(vim.lsp.config.terraformls.root_dir, buf)
  local problems = {}
  want(problems, vim.deep_equal(dirs, { dir }), "on_dir calls " .. show(dirs))
  want(problems, #events == 0, "events " .. show(events))
  return joined(problems)
end)

-- L8: with the CLI and no UI to answer a trust prompt, it never starts and never asks
case("L8-terraformls-headless", function()
  vim.env.PATH = bins.terraform
  local events = stub_trust(false, { "allow" })
  load_spec "lsp"
  local _, buf = project "L8"
  local dirs = root_dirs(vim.lsp.config.terraformls.root_dir, buf)
  local problems = {}
  want(problems, #dirs == 0, "on_dir calls " .. show(dirs))
  want(problems, #reads_of(events) == 0, "vim.secure.read called: " .. show(events))
  return joined(problems)
end)

-- L9: with the CLI and a UI, vim.secure.read decides. A first prompt comes with a notice saying why;
-- a declined root is not asked again until config() runs again; an allowed one is asked every time.
-- L9a and L9b share one load.
local l9_root_dir
case("L9a-notice-then-ask", function()
  vim.env.PATH = bins.terraform
  local events = stub_trust(true, { "ignore" })
  load_spec "lsp"
  l9_root_dir = vim.lsp.config.terraformls.root_dir
  local dir, buf = project "L9"
  local problems = {}
  want(problems, vim.fn.filereadable(trust_file()) == 0, "trust file present")
  local dirs = root_dirs(l9_root_dir, buf)
  want(problems, #dirs == 0, "on_dir calls " .. show(dirs))
  local notice, read = events[1] or {}, events[2] or {}
  want(
    problems,
    #events == 2
      and notice[1] == "notify"
      and notice[3] == vim.log.levels.INFO
      and notice[2]:find(dir, 1, true)
      and notice[2]:find(".terraform", 1, true)
      and vim.deep_equal(read, { "read", dir }),
    "want an INFO notice naming " .. dir .. "/.terraform, then vim.secure.read(" .. dir .. "); got " .. show(events)
  )
  return joined(problems)
end)

case("L9b-declined-cached", function()
  vim.env.PATH = bins.terraform
  local events = stub_trust(true, { "allow" })
  if not l9_root_dir then
    return "L9a did not load the spec"
  end
  local _, buf = project "L9"
  local dirs = root_dirs(l9_root_dir, buf)
  local problems = {}
  want(problems, #dirs == 0, "on_dir calls " .. show(dirs))
  want(problems, #events == 0, "events " .. show(events))
  return joined(problems)
end)

-- An answered root (a trust database line names it) gets no notice, but vim.secure.read still decides
case("L9c-answered-no-notice", function()
  vim.env.PATH = bins.terraform
  local events = stub_trust(true, { "allow" })
  load_spec "lsp"
  local dir, buf = project "L9c"
  vim.fn.mkdir(vim.fn.stdpath "state", "p")
  vim.fn.writefile({ "0123abcd " .. vim.uv.fs_realpath(dir) }, trust_file())
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

case("L9d-allow-rechecked", function()
  vim.env.PATH = bins.terraform
  local events = stub_trust(true, { "allow", "allow" })
  load_spec "lsp"
  local dir, buf = project "L9d"
  local dirs = root_dirs(vim.lsp.config.terraformls.root_dir, buf)
  vim.list_extend(dirs, root_dirs(vim.lsp.config.terraformls.root_dir, buf))
  local reads = reads_of(events)
  local problems = {}
  want(problems, #reads == 2, #reads .. " vim.secure.read calls: " .. show(events))
  want(problems, vim.deep_equal(dirs, { dir, dir }), "on_dir calls " .. show(dirs))
  return joined(problems)
end)

case("L9e-config-resets-cache", function()
  vim.env.PATH = bins.terraform
  local events = stub_trust(true, { "ignore", "ignore" })
  local spec = load_spec "lsp"
  local _, buf = project "L9e"
  root_dirs(vim.lsp.config.terraformls.root_dir, buf)
  spec.config()
  root_dirs(vim.lsp.config.terraformls.root_dir, buf)
  local reads = reads_of(events)
  if #reads ~= 2 then
    return #reads .. " vim.secure.read calls (want 2): " .. show(events)
  end
end)

vim.fn.delete(tmp, "rf")
say("exit=" .. failed)
io.flush()
-- :cquit rather than os.exit(), which skips Neovim's exit and leaves its temp dir behind
vim.cmd.cquit { count = failed }
