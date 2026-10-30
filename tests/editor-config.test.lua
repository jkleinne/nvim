-- Tests for the editor settings that keep repo code from running and tools from phoning home
-- (lua/plugins/lsp.lua with its server list and gates in lua/lsp_gates/, lua/plugins/lint.lua,
-- lua/plugins/conform.lua, lua/settings.lua, and init.lua's load order):
-- nvim --clean --headless -l tests/editor-config.test.lua
--
-- Hermetic: XDG_STATE_HOME, XDG_DATA_HOME, and XDG_CACHE_HOME point at a scratch dir (removed at the
-- end) before anything calls stdpath, so the real trust database and data dirs are never read or
-- written; setting them inside this nvim is enough, because stdpath reads the environment on each
-- call (checked below before any test runs). The scratch dir is a resolved path: Neovim resolves
-- symlinks in the names of existing files, and TMPDIR may be a symlink. It must not be inside a
-- project (a .terraform or .git above it would change the roots the cases expect), and
-- 'runtimepath' holds only $VIMRUNTIME (--clean keeps the system site dirs, where an lsp/*.lua
-- would change what vim.lsp.config resolves) until L15c, the last case, prepends a scratch
-- lazy.nvim dir. The plugins are stub modules in package.loaded; the lsp_gates modules are the real
-- ones. Every case starts with PATH set to an empty scratch dir and Arch's TypeScript path
-- (lsp_gates.typescript.ARCH_TSSERVER) pointing at a missing scratch path; the cases that depend on
-- which commands exist set PATH to scratch dirs of stub commands (they exit 1 and no test runs
-- them), and the TypeScript cases point ARCH_TSSERVER at a scratch package. The trust cases use the
-- real vim.secure functions on the scratch trust database. Stubbed per case and restored after it:
-- vim.notify, vim.fn.confirm (a trust prompt is recorded and cancelled, so it never waits for
-- input), vim.secure.read (wrapped to record its calls), vim.lsp.enable and vim.cmd.doautoall
-- (recorded instead of run in the :TerraformTrust cases), vim.secure.trust (L10f), vim.uv.getuid
-- (L8b, L9k, L10c, L10h), vim.uv.os_get_passwd (L10c), HOME, and EDITOR_TEST_ALIAS (L9m, L9n,
-- L10i); the gates' per-session notices are reset. L10g wraps vim.lsp's functions around one call
-- and restores them itself. L15c stubs the lazy module and removes the stub itself; it leaves
-- vim.loader enabled, with its cache in the scratch dir. Nothing is installed or downloaded, and no
-- language server starts. Exits nonzero when a test fails.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:gsub("^@", ""), ":p:h:h")
-- Resolved before any path is built from it, so those paths match the (resolved) buffer names
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
tmp = assert(vim.uv.fs_realpath(tmp))

-- Stops the run before any test, with a FAIL line saying why
local function setup_failure(reason)
  vim.fn.delete(tmp, "rf")
  io.write(("FAIL setup: %s; stopping\nexit=1\n"):format(reason))
  vim.cmd.cquit { count = 1 }
end

vim.env.XDG_STATE_HOME = tmp .. "/state"
vim.env.XDG_DATA_HOME = tmp .. "/data"
vim.env.XDG_CACHE_HOME = tmp .. "/cache"
for _, kind in ipairs { "state", "data", "cache" } do
  if not vim.startswith(vim.fn.stdpath(kind), tmp .. "/") then
    setup_failure(("stdpath(%q) is %s, not under %s"):format(kind, vim.fn.stdpath(kind), tmp))
  end
end

-- L15c runs init.lua, which enables vim.loader. Its byte cache path is fixed when vim.loader first
-- loads, so it must already point under the scratch dir (vim.loader.path is a private field, hence
-- the type check).
local loader_path = vim.loader.path
if type(loader_path) ~= "string" or not vim.startswith(loader_path, tmp .. "/") then
  setup_failure(("vim.loader.path is %s, not under %s"):format(tostring(loader_path), tmp))
end

-- lsp.lua requires its gates from lua/lsp_gates/, and --clean leaves this config off 'runtimepath'
package.path = root .. "/lua/?.lua;" .. package.path
vim.o.runtimepath = vim.env.VIMRUNTIME
vim.o.packpath = vim.env.VIMRUNTIME

local project_marker = vim.fs.root(tmp, { ".terraform", ".git" })
if project_marker then
  setup_failure(("%s has a .terraform or .git; set TMPDIR to a dir outside any project"):format(project_marker))
end

local typescript = require "lsp_gates.typescript"
local terraform_trust = require "lsp_gates.terraform_trust"
local reasons = terraform_trust.REASONS

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

-- The lists one after another, in a new list
local function concat(...)
  local all = {}
  for _, list in ipairs { ... } do
    vim.list_extend(all, list)
  end
  return all
end

-- Texts the gates' notices contain (the refusal reasons come from terraform_trust.REASONS)
local text = {
  trust_command = ":TerraformTrust",
  override_hint = "run :TerraformTrust! to trust it anyway (that covers every project below it)",
  owner_rule = "terraform-ls starts only in directories you own that are not world-writable",
  save_first = "save the file first",
  not_a_file = "buffer that shows a file",
  no_expansion = "no $NAME that Neovim would expand",
  allowed = "terraform-ls allowed in ",
  resolved_line_break = "its resolved path has a line break",
  not_read_back = "could not read it back",
  no_typescript = "ts_ls is off: no system TypeScript found",
}

-- ---------------------------------------------------------------------------
-- Stubs
-- ---------------------------------------------------------------------------

local original = {
  path = vim.env.PATH,
  home = vim.env.HOME,
  editor_test_alias = vim.env.EDITOR_TEST_ALIAS,
  arch_tsserver = typescript.ARCH_TSSERVER,
  confirm = vim.fn.confirm,
  doautoall = vim.cmd.doautoall,
  lsp_enable = vim.lsp.enable,
  secure_read = vim.secure.read,
  secure_trust = vim.secure.trust,
  notify = vim.notify,
  getuid = vim.uv.getuid,
  os_get_passwd = vim.uv.os_get_passwd,
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
local never_names = { "esbonio", "golangci_lint_ls", "terraform_lsp", "tflint", "tofu_ls", "tvm_ffi_navigator" }
local server_names = vim.tbl_keys(system_cmds)
table.sort(server_names)
local server_bins = {}
for _, name in ipairs(server_names) do
  server_bins[#server_bins + 1] = system_cmds[name][1]
end
-- Every config a case can enable or change
local lsp_names = concat(mason_names, server_names, retired_names, never_names)

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
for _, name in ipairs(concat(retired_names, never_names)) do
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
-- and cancels it, and a vim.notify that records. Calls, prompts, and notices go to one ordered list
-- of events { kind = "read" | "prompt" | "notify", msg = <path or text>, level = <notify level> }.
local function record_events()
  local events = {}
  local function record(kind, msg, level)
    events[#events + 1] = { kind = kind, msg = msg, level = level }
  end
  vim.secure.read = function(path)
    record("read", path)
    return original.secure_read(path)
  end
  vim.fn.confirm = function(msg)
    record("prompt", msg)
    return 0
  end
  vim.notify = function(msg, level)
    record("notify", msg, level)
  end
  return events
end

-- Records vim.lsp.enable and vim.cmd.doautoall calls instead of running them. Returns the calls and
-- a function that puts the real ones back.
local function record_activation()
  local calls = {}
  vim.lsp.enable = function(...)
    calls[#calls + 1] = { "enable", ... }
  end
  vim.cmd.doautoall = function(...)
    calls[#calls + 1] = { "doautoall", ... }
  end
  return calls, function()
    vim.lsp.enable = original.lsp_enable
    vim.cmd.doautoall = original.doautoall
  end
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
  local ok, message = original.secure_trust { action = action, path = dir }
  assert(ok, message)
end

-- Writes the scratch trust database by hand (for lines vim.secure.trust never writes)
local function write_trust(lines)
  vim.fn.mkdir(vim.fn.stdpath "state", "p")
  vim.fn.writefile(lines, trust_file())
end

-- A trust-database hash that is a file's content hash: neither "directory" nor "!"
local file_hash = string.rep("0123456789abcdef", 4)

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

-- Whether event is a notice at level whose text contains every one of texts and none of
-- absent_texts (plain substrings)
local function is_notice(event, level, texts, absent_texts)
  if event == nil or event.kind ~= "notify" or event.level ~= level then
    return false
  end
  for _, part in ipairs(texts) do
    if not event.msg:find(part, 1, true) then
      return false
    end
  end
  for _, part in ipairs(absent_texts or {}) do
    if event.msg:find(part, 1, true) then
      return false
    end
  end
  return true
end

-- Whether event is the INFO notice that names dir and :TerraformTrust
local function is_trust_notice(event, dir)
  return is_notice(event, vim.log.levels.INFO, { dir, text.trust_command })
end

-- The texts a refusal of root for reason gives: :TerraformTrust! where the gate would honor trust
-- (overridable), else the owner rule and not :TerraformTrust!, and never :trust (Neovim 0.12's
-- :trust <dir> fails with E475). Returns texts, absent_texts.
local function advice_texts(root_dir, reason, overridable)
  local texts = { root_dir .. " (" .. reason .. ")" }
  if overridable then
    texts[2] = text.override_hint
    return texts, { ":trust" }
  end
  texts[2] = text.owner_rule
  return texts, { ":trust", ":TerraformTrust!" }
end

-- The command a refusal's hint (the text after "; ") names, without its colon, or nil
local function hinted_command(msg)
  local hint = msg:match "; (.*)$"
  return hint and hint:match ":(%S+)"
end

-- Calls a root_dir function and returns the dirs it passed to on_dir
local function root_dirs(root_dir, buf)
  local dirs = {}
  root_dir(buf, function(dir)
    dirs[#dirs + 1] = dir
  end)
  return dirs
end

-- Problems unless each named server's root_dir is a function that never calls on_dir for buf
local function refusing_problems(names, buf)
  local problems = {}
  for _, name in ipairs(names) do
    local root_dir = (vim.lsp.config[name] or {}).root_dir
    if type(root_dir) ~= "function" then
      want(problems, false, name .. " root_dir " .. show(root_dir))
    else
      local dirs = root_dirs(root_dir, buf)
      want(problems, #dirs == 0, name .. " on_dir calls " .. show(dirs))
    end
  end
  return problems
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

-- The trust database's bytes, or nil when there is none
local function trust_bytes()
  local f = io.open(trust_file(), "rb")
  if not f then
    return nil
  end
  local bytes = f:read "*a"
  f:close()
  return bytes
end

-- Runs command (default TerraformTrust) from buf with fresh activation records. Problems unless it
-- ran without error, gave exactly one WARN notice containing each of texts and none of absent_texts
-- (plain substrings), left the trust database byte-identical, and activated nothing.
local function refused_problems(label, buf, events, texts, absent_texts, command)
  vim.fn.mkdir(vim.fn.stdpath "state", "p")
  local before_bytes = trust_bytes()
  vim.api.nvim_set_current_buf(buf)
  local calls, undo = record_activation()
  local before = #events
  local ok, err = pcall(vim.cmd, command or "TerraformTrust")
  undo()
  local notices = vim.list_slice(events, before + 1)
  local problems = {}
  want(problems, ok, label .. ": error " .. tostring(err))
  want(
    problems,
    #notices == 1 and is_notice(notices[1], vim.log.levels.WARN, texts, absent_texts),
    label
      .. ": want one WARN notice with "
      .. show(texts)
      .. (absent_texts and #absent_texts > 0 and (" and without " .. show(absent_texts)) or "")
      .. "; got "
      .. show(notices)
  )
  want(problems, trust_bytes() == before_bytes, label .. ": trust database changed to " .. show(trust_lines()))
  want(problems, #calls == 0, label .. ": activation calls " .. show(calls))
  return problems
end

-- A directory literally named $EDITOR_TEST_ALIAS in <tmp>/<name>-dl, holding main.tf, with
-- EDITOR_TEST_ALIAS set so that vim.fs.normalize turns that directory's path into one that resolves
-- to target: "alias", with <dl>/alias linking to target, or (absolute) target's own path, with a
-- link like <dl>/tmp -> /tmp for its first component (normalize joins the doubled slash). Returns
-- the literal directory and a buffer for its main.tf.
local function dollar_name_tree(name, target, absolute)
  local dl = tmp .. "/" .. name .. "-dl"
  local literal = dl .. "/$EDITOR_TEST_ALIAS"
  vim.fn.mkdir(literal, "p")
  vim.fn.writefile({}, literal .. "/main.tf")
  if absolute then
    local top = target:match "^/[^/]+"
    assert(vim.uv.fs_symlink(top, dl .. top))
    vim.env.EDITOR_TEST_ALIAS = target
  else
    assert(vim.uv.fs_symlink(target, dl .. "/alias"))
    vim.env.EDITOR_TEST_ALIAS = "alias"
  end
  local resolved = vim.uv.fs_realpath(vim.fs.normalize(literal))
  assert(resolved == target, ("%s normalizes onto %s, not %s"):format(literal, tostring(resolved), target))
  return literal, vim.fn.bufadd(literal .. "/main.tf")
end

-- Undoes every stub and every LSP setting a case made
local function restore()
  vim.env.PATH = original.path
  vim.env.HOME = original.home
  vim.env.EDITOR_TEST_ALIAS = original.editor_test_alias
  typescript.ARCH_TSSERVER = original.arch_tsserver
  vim.fn.confirm = original.confirm
  vim.cmd.doautoall = original.doautoall
  vim.lsp.enable = original.lsp_enable
  vim.secure.read = original.secure_read
  vim.secure.trust = original.secure_trust
  vim.notify = original.notify
  vim.uv.getuid = original.getuid
  vim.uv.os_get_passwd = original.os_get_passwd
  terraform_trust.reset()
  typescript.reset()
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

-- What every case starts from: no commands on PATH and no Arch TypeScript
local function begin_case()
  vim.env.PATH = bins.none
  arch_typescript(false)
end

-- Runs fn, which returns nil to pass or a string of problems, and prints the result line
local function case(id, fn)
  begin_case()
  local ok, problems = xpcall(fn, debug.traceback)
  restore()
  if not ok then
    problems = "error: " .. tostring(problems):gsub("\n%s*", " | ")
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

-- L1: Mason installs only the native servers, and its automatic enable skips the system servers,
-- the retired ones, and the ones that never start (with or without a system TypeScript), so only
-- lsp.lua's gates start the system servers and a leftover Mason copy of the others is never enabled
-- automatically
case("L1-mason-list", function()
  local want_exclude = concat(retired_names, never_names, server_names)
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
-- commands, retired list, and never-start list equal it, and a different inventory in its place
-- changes them
case("L1b-servers-module", function()
  local servers = require "lsp_gates.servers"
  local problems = {}
  want(problems, vim.deep_equal(servers.mason, mason_names), "module mason " .. show(servers.mason))
  want(problems, vim.deep_equal(servers.system, system_cmds), "module system " .. show(servers.system))
  want(problems, vim.deep_equal(servers.retired, retired_names), "module retired " .. show(servers.retired))
  want(problems, vim.deep_equal(servers.never, never_names), "module never " .. show(servers.never))

  -- Problems unless lsp.lua's lists (from its last config run) equal inventory
  local function lists_problems(label, inventory)
    local list_problems = {}
    local opts = mason_setup_opts or {}
    want(
      list_problems,
      vim.deep_equal(opts.ensure_installed, inventory.mason),
      label .. "ensure_installed " .. show(opts.ensure_installed)
    )
    local want_exclude = concat(vim.tbl_keys(inventory.system), inventory.retired, inventory.never)
    table.sort(want_exclude)
    local exclude = vim.tbl_get(opts, "automatic_enable", "exclude")
    want(list_problems, vim.deep_equal(exclude, want_exclude), label .. "exclude " .. show(exclude))
    for _, name in ipairs(server_names) do
      local cmd = (vim.lsp.config[name] or {}).cmd
      want(list_problems, vim.deep_equal(cmd, inventory.system[name]), label .. name .. " cmd " .. show(cmd))
    end
    local never_start = concat(inventory.retired, inventory.never)
    for _, name in ipairs(concat(retired_names, never_names)) do
      local root_dir = (vim.lsp.config[name] or {}).root_dir
      local refused = vim.list_contains(never_start, name)
      want(
        list_problems,
        (type(root_dir) == "function") == refused,
        label .. name .. " root_dir " .. show(root_dir) .. (refused and " (never starts)" or " (not listed)")
      )
    end
    return list_problems
  end

  load_spec "lsp"
  vim.list_extend(problems, lists_problems("", servers))

  restore()
  begin_case()
  local other = {
    mason = { "gopls" },
    system = { bashls = { "other-bash-server", "start" } },
    retired = { "sqlls" },
    never = { "tflint" },
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
  return joined(refusing_problems(retired_names, buf))
end)

-- L1d: the known lspconfig servers that run a repo's code with tools this config installs or trusts
-- (tflint plugins, a repo's .golangci.yml, terraform providers, a repo's Python modules through
-- python -m) never start: each one's root_dir never hands Neovim a root, even when a bare :lsp
-- enable enables it, and mason-lspconfig's automatic enable skips them
case("L1d-never-servers", function()
  load_spec "lsp"
  local _, buf = project "L1d"
  local problems = refusing_problems(never_names, buf)
  local exclude = vim.tbl_get(mason_setup_opts or {}, "automatic_enable", "exclude") or {}
  for _, name in ipairs(never_names) do
    want(problems, vim.list_contains(exclude, name), name .. " not excluded: " .. show(exclude))
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

-- A ts_ls project dir with a .git dir and a package-lock.json, and an (unloaded) buffer for its
-- index.ts
local function ts_project(name)
  local dir = tmp .. "/project-" .. name
  vim.fn.mkdir(dir .. "/.git", "p")
  vim.fn.writefile({}, dir .. "/package-lock.json")
  vim.fn.writefile({}, dir .. "/index.ts")
  return dir, vim.fn.bufadd(dir .. "/index.ts")
end

-- L4e: without a system TypeScript, ts_ls's root_dir never hands Neovim a root, so not even
-- :lsp enable ts_ls starts it with the workspace's TypeScript. With one, the root is what the
-- root_dir configured before lsp.lua's (lspconfig's) hands over.
case("L4e-ts_ls-refuses-without-typescript", function()
  vim.env.PATH = bins.servers
  record_events()
  local upstream_root = tmp .. "/L4e-upstream-root"
  local upstream_calls = {}
  local function configure_upstream()
    vim.lsp.config.ts_ls = {}
    vim.lsp.config("ts_ls", {
      root_dir = function(bufnr, on_dir)
        upstream_calls[#upstream_calls + 1] = bufnr
        on_dir(upstream_root)
      end,
    })
  end
  local _, buf = ts_project "L4e"
  local problems = {}

  configure_upstream()
  arch_typescript(false)
  load_spec "lsp"
  local root_dir = (vim.lsp.config.ts_ls or {}).root_dir
  if type(root_dir) ~= "function" then
    return "without TypeScript: root_dir " .. show(root_dir)
  end
  local dirs = root_dirs(root_dir, buf)
  want(problems, #dirs == 0, "without TypeScript: on_dir calls " .. show(dirs))
  want(problems, #upstream_calls == 0, "without TypeScript: upstream root_dir calls " .. show(upstream_calls))

  configure_upstream()
  arch_typescript(true)
  load_spec "lsp"
  root_dir = (vim.lsp.config.ts_ls or {}).root_dir
  if type(root_dir) ~= "function" then
    want(problems, false, "with TypeScript: root_dir " .. show(root_dir))
    return joined(problems)
  end
  dirs = root_dirs(root_dir, buf)
  want(problems, vim.deep_equal(dirs, { upstream_root }), "with TypeScript: on_dir calls " .. show(dirs))
  want(
    problems,
    vim.deep_equal(upstream_calls, { buf }),
    "with TypeScript: upstream root_dir calls " .. show(upstream_calls)
  )
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

-- Whether event is ts_ls's INFO notice that it is off for want of a system TypeScript
local function is_typescript_notice(event)
  return is_notice(event, vim.log.levels.INFO, { text.no_typescript })
end

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
  local _, buf = ts_project "L4i"
  local dirs = root_dirs(root_dir, buf)
  vim.list_extend(dirs, root_dirs(root_dir, buf))
  local problems = {}
  want(problems, #dirs == 0, "on_dir calls " .. show(dirs))
  want(
    problems,
    #events == 1 and is_typescript_notice(events[1]),
    "want one INFO notice over two calls; got " .. show(events)
  )
  spec.config()
  root_dirs((vim.lsp.config.ts_ls or {}).root_dir, buf)
  want(
    problems,
    #events == 2 and is_typescript_notice(events[2]),
    "want a notice after config() again; got " .. show(events)
  )
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

-- L4k: with a system TypeScript at config time, ts_ls's root_dir checks the package again on each
-- call: once it is gone (removed mid-session), there is no root (typescript-language-server would
-- load the workspace's TypeScript), and one notice over two calls says why
case("L4k-ts_ls-recheck", function()
  vim.env.PATH = bins.servers
  local events = record_events()
  local js = fake_package("L4k", typescript_package_json)
  typescript.ARCH_TSSERVER = js
  load_spec "lsp"
  local root_dir = (vim.lsp.config.ts_ls or {}).root_dir
  if type(root_dir) ~= "function" then
    return "root_dir " .. show(root_dir)
  end
  local dir, buf = ts_project "L4k"
  local problems = {}
  local dirs = root_dirs(root_dir, buf)
  want(problems, vim.deep_equal(dirs, { dir }), "TypeScript present: on_dir calls " .. show(dirs))
  vim.fn.delete(vim.fs.dirname(vim.fs.dirname(js)), "rf")
  dirs = root_dirs(root_dir, buf)
  vim.list_extend(dirs, root_dirs(root_dir, buf))
  want(problems, #dirs == 0, "TypeScript removed: on_dir calls " .. show(dirs))
  want(
    problems,
    #events == 1 and is_typescript_notice(events[1]),
    "want one INFO notice over two calls; got " .. show(events)
  )
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

-- L8b: the notice fits the root: one :TerraformTrust refuses but the gate would honor (here the home
-- directory) names :TerraformTrust! for trusting it anyway, one owned by another user gives the
-- owner rule and names neither that nor :trust, and one that does not exist yet (a new file in a
-- new directory) says to save the file first, as :TerraformTrust itself does there
case("L8b-notice-variants", function()
  local events, home, home_buf = terraform_setup "L8b-home"
  vim.env.HOME = home
  local problems = {}

  -- Problems unless root_dir for buf gives no root and exactly one INFO notice containing each of
  -- texts and none of absent_texts
  local function notice_problems(label, buf, texts, absent_texts)
    local before = #events
    local dirs = root_dirs(vim.lsp.config.terraformls.root_dir, buf)
    local notices = vim.list_slice(events, before + 1)
    want(problems, #dirs == 0, label .. ": on_dir calls " .. show(dirs))
    want(
      problems,
      #notices == 1 and is_notice(notices[1], vim.log.levels.INFO, texts, absent_texts),
      label .. ": want one INFO notice with " .. show(texts) .. "; got " .. show(notices)
    )
  end

  notice_problems("home", home_buf, advice_texts(home, reasons.home, true))

  local foreign, foreign_buf = project "L8b-foreign"
  local uid = original.getuid()
  vim.uv.getuid = function()
    return uid + 1
  end
  notice_problems("foreign-owned", foreign_buf, advice_texts(foreign, reasons.not_owned, false))
  vim.uv.getuid = original.getuid

  local missing = tmp .. "/L8b-missing"
  local missing_buf = vim.fn.bufadd(missing .. "/main.tf")
  local missing_root = terraform_trust.root(missing_buf)
  want(problems, missing_root == missing, "missing dir: root " .. show(missing_root))
  notice_problems("missing dir", missing_buf, { text.save_first, text.trust_command })
  vim.list_extend(problems, refused_problems("missing dir, :TerraformTrust", missing_buf, events, { text.save_first }))
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
  write_trust { file_hash .. " " .. dir }
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
-- allows it (Neovim resolves the link in the name of an existing file, so opening main.tf through
-- the link gives the same buffer), and the gate allows the link path too, while a hand-written line
-- for the unresolved link path alone allows neither
case("L9h-realpath-keying", function()
  local events, dir, buf = terraform_setup "L9h"
  local link = tmp .. "/L9h-link"
  assert(vim.uv.fs_symlink(dir, link))
  local link_buf = vim.fn.bufadd(link .. "/main.tf")
  local problems = {}
  want(
    problems,
    link_buf == buf,
    "opened through the link: buffer " .. link_buf .. " " .. show(vim.api.nvim_buf_get_name(link_buf))
  )
  trust("allow", link)
  local dirs = root_dirs(vim.lsp.config.terraformls.root_dir, buf)
  want(problems, vim.deep_equal(dirs, { dir }), "trusted through the link: on_dir calls " .. show(dirs))
  want(problems, terraform_trust.allowed(link), "trusted through the link: allowed(link) false")
  want(problems, terraform_trust.allowed(dir), "trusted through the link: allowed(dir) false")
  write_trust { "directory " .. link }
  want(problems, not terraform_trust.allowed(link), "unresolved link line: allowed(link) true")
  want(problems, not terraform_trust.allowed(dir), "unresolved link line: allowed(dir) true")
  dirs = root_dirs(vim.lsp.config.terraformls.root_dir, buf)
  want(problems, #dirs == 0, "unresolved link line: on_dir calls " .. show(dirs))
  local asked = vim.tbl_filter(function(event)
    return event.kind ~= "notify"
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

-- L9k: the gate checks ownership each time it runs, not only when :TerraformTrust writes the entry:
-- an allowed root owned by another user never starts, and its notice gives the owner rule, not
-- :trust
case("L9k-trusted-foreign-refused", function()
  local events, dir, buf = terraform_setup "L9k"
  trust("allow", dir)
  local uid = original.getuid()
  vim.uv.getuid = function()
    return uid + 1
  end
  local dirs = root_dirs(vim.lsp.config.terraformls.root_dir, buf)
  local problems = {}
  want(problems, #dirs == 0, "on_dir calls " .. show(dirs))
  local texts, absent_texts = advice_texts(dir, reasons.not_owned, false)
  want(
    problems,
    #events == 1 and is_notice(events[1], vim.log.levels.INFO, texts, absent_texts),
    "want one INFO notice with " .. show(texts) .. " and without :trust; got " .. show(events)
  )
  return joined(problems)
end)

-- L9l: the gate checks the mode each time it runs too: an allowed root the user owns that anyone
-- can write (anyone could create a .terraform in it) never starts, and its notice gives the owner
-- rule, not :trust
case("L9l-trusted-world-writable-refused", function()
  local events, dir, buf = terraform_setup "L9l"
  trust("allow", dir)
  assert(vim.uv.fs_chmod(dir, tonumber("777", 8)))
  local dirs = root_dirs(vim.lsp.config.terraformls.root_dir, buf)
  local problems = {}
  want(problems, #dirs == 0, "on_dir calls " .. show(dirs))
  local texts, absent_texts = advice_texts(dir, reasons.world_writable, false)
  want(
    problems,
    #events == 1 and is_notice(events[1], vim.log.levels.INFO, texts, absent_texts),
    "want one INFO notice with " .. show(texts) .. " and without :trust; got " .. show(events)
  )
  return joined(problems)
end)

-- L9m: vim.fs.root and vim.secure key on the path vim.fs.normalize gives, which expands $NAME from
-- the environment, while terraform-ls would start in the literal directory. A file in a directory
-- literally named $EDITOR_TEST_ALIAS that normalizes onto an allowed directory (with no .terraform
-- or .git, so the root would be the file's own directory) has no root: terraform-ls never starts
-- there, no notice shows, and :TerraformTrust and :TerraformTrust! refuse it, leaving the database
-- as it was
case("L9m-dollar-name-fallback", function()
  local events = terraform_setup "L9m"
  local trusted = tmp .. "/L9m-trusted"
  vim.fn.mkdir(trusted, "p")
  trust("allow", trusted)
  local _, buf = dollar_name_tree("L9m", trusted, false)
  local problems = {}
  local got_root = terraform_trust.root(buf)
  want(problems, got_root == nil, "root " .. show(got_root))
  local dirs = root_dirs(vim.lsp.config.terraformls.root_dir, buf)
  want(problems, #dirs == 0, "on_dir calls " .. show(dirs))
  want(problems, #events == 0, "events " .. show(events))
  for _, command in ipairs { "TerraformTrust", "TerraformTrust!" } do
    vim.list_extend(
      problems,
      refused_problems(":" .. command, buf, events, { text.not_a_file, text.no_expansion }, {}, command)
    )
  end
  return joined(problems)
end)

-- L9n: the same with markers: the allowed directory is a project (a .git), so vim.fs.root, searching
-- from the directory the name normalizes to, returns that path, while main.tf's own directory holds
-- a .terraform. EDITOR_TEST_ALIAS names the project relatively (through <dl>/alias) and absolutely
-- (its own path, through a link like <dl>/tmp -> /tmp). Neither file has a root, terraform-ls never
-- starts for it, and no notice shows.
case("L9n-dollar-name-marker", function()
  local events, trusted = terraform_setup "L9n"
  trust("allow", trusted)
  local problems = {}
  for _, absolute in ipairs { false, true } do
    local label = absolute and "absolute" or "relative"
    local literal, buf = dollar_name_tree("L9n-" .. label, trusted, absolute)
    vim.fn.mkdir(literal .. "/.terraform", "p")
    local expanded = vim.fs.root(buf, { ".terraform", ".git" })
    want(
      problems,
      expanded ~= nil and vim.uv.fs_realpath(expanded) == trusted,
      label .. ": setup: vim.fs.root gives " .. show(expanded) .. ", not a path to " .. trusted
    )
    local got_root = terraform_trust.root(buf)
    want(problems, got_root == nil, label .. ": root " .. show(got_root))
    local dirs = root_dirs(vim.lsp.config.terraformls.root_dir, buf)
    want(problems, #dirs == 0, label .. ": on_dir calls " .. show(dirs))
  end
  want(problems, #events == 0, "events " .. show(events))
  return joined(problems)
end)

-- L9o: a root the user owns that the group can write (0775, as a 002 umask makes it) counts: the gate
-- checks only for world-writable roots. :TerraformTrust trusts it and terraform-ls starts there. This
-- pins an accepted residual, so a change to it is deliberate.
case("L9o-group-writable-allowed", function()
  local events, dir, buf = terraform_setup "L9o"
  assert(vim.uv.fs_chmod(dir, tonumber("775", 8)))
  local problems = {}
  local refusal = terraform_trust.refusal(dir)
  want(problems, refusal == nil, "refusal " .. show(refusal))
  vim.fn.mkdir(vim.fn.stdpath "state", "p")
  vim.api.nvim_set_current_buf(buf)
  vim.cmd "TerraformTrust"
  want(
    problems,
    #events == 1 and is_notice(events[1], vim.log.levels.INFO, { text.allowed .. dir }),
    "want one INFO notice that it is allowed; got " .. show(events)
  )
  want(problems, terraform_trust.allowed(dir), "allowed(dir) false after :TerraformTrust")
  local dirs = root_dirs(vim.lsp.config.terraformls.root_dir, buf)
  want(problems, vim.deep_equal(dirs, { dir }), "on_dir calls " .. show(dirs))
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

-- L10b: from a buffer with a 'buftype' (here nofile) :TerraformTrust refuses: vim.fs.root would
-- start from the cwd, so the root would not be this file's
case("L10b-terraform-trust-nofile", function()
  local events, dir = terraform_setup "L10b"
  return joined(refused_problems("nofile", nofile_buffer(dir), events, { text.not_a_file }))
end)

-- L10c: :TerraformTrust refuses roots where trust would cover far more than one project, and roots
-- someone else controls or anyone can write, and names the reason. It suggests :TerraformTrust!
-- only where the gate would honor trust, in a directory the user owns that is not world-writable:
-- the home directory (found through a symlinked HOME, or through the passwd entry when HOME is
-- unset) and a parent of it the user owns. For /, a root-owned parent of HOME, a world-writable
-- directory (the user's or, like /tmp, root's), and a directory owned by another user, it gives the
-- owner rule.
case("L10c-terraform-trust-advice", function()
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
  -- The owner a system directory's target runs with: its own (root) unless the test runs as its
  -- owner, which then counts as another user
  local function system_owner(dir)
    return assert(vim.uv.fs_stat(dir)).uid == uid and other_user or nil
  end
  -- A buffer for a new file in dir, whose root is dir (the setup check rules out a .terraform or
  -- .git in /)
  local function system_buf(dir)
    return vim.fn.bufadd(vim.fs.joinpath(dir, "editor-config-test-L10c.tf"))
  end
  -- /tmp when it is world-writable (as on any Linux system), else the scratch world-writable dir
  -- with a stubbed owner. Its HOME is /usr/bin, because the scratch home may be under /tmp.
  local shared_dir, shared_getuid = "/tmp", system_owner "/tmp"
  if require("bit").band(assert(vim.uv.fs_stat "/tmp").mode, tonumber("002", 8)) == 0 then
    shared_dir, shared_getuid = open, other_user
  end
  -- Each target: { label, buffer, HOME, reason, overridable, getuid, passwd home }
  local targets = {
    { "/", system_buf "/", home, reasons.filesystem_root, false, system_owner "/" },
    { "home", home_buf, home, reasons.home, true },
    { "symlinked home", home_buf, home_link, reasons.home, true },
    { "HOME unset, passwd home", home_buf, nil, reasons.home, true, nil, home },
    { "user's parent of home", parent_buf, parent .. "/home", reasons.home_parent, true },
    { "root's parent of home", system_buf "/usr", "/usr/bin", reasons.home_parent, false, system_owner "/usr" },
    { "user's world-writable dir", open_buf, home, reasons.world_writable, false },
    { "root's world-writable dir", system_buf(shared_dir), "/usr/bin", reasons.world_writable, false, shared_getuid },
    { "foreign-owned", foreign_buf, home, reasons.not_owned, false, other_user },
  }
  local problems = {}
  for _, target in ipairs(targets) do
    local label, buf, reason, overridable, passwd_home = target[1], target[2], target[4], target[5], target[7]
    vim.env.HOME = target[3]
    vim.uv.getuid = target[6] or original.getuid
    if passwd_home then
      vim.uv.os_get_passwd = function()
        return vim.tbl_extend("force", original.os_get_passwd() or {}, { homedir = passwd_home })
      end
    end
    local root_dir = terraform_trust.root(buf)
    if root_dir == nil then
      want(problems, false, label .. ": no root")
    else
      local texts, absent_texts = advice_texts(root_dir, reason, overridable)
      vim.list_extend(problems, refused_problems(label, buf, events, texts, absent_texts))
    end
    vim.uv.getuid = original.getuid
    vim.uv.os_get_passwd = original.os_get_passwd
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
-- named "p\ndirectory <HOME>\nz" would add a line that trusts HOME. A root with a line break has no
-- root at all: :TerraformTrust refuses (one WARN, nothing written), and terraform-ls never starts
-- there, even with an entry Neovim's own :trust wrote (a carriage return, which the database keeps
-- inside its line). The resolved path counts too: a file :w ++p creates in a new directory through
-- a symlink keeps the link's path as its buffer name, and the command refuses a root whose resolved
-- path has a line break.
case("L10e-line-break-root", function()
  local events, home = terraform_setup "L10e-home"
  vim.env.HOME = home
  local injected = tmp .. "/p\ndirectory " .. home .. "\nz"
  vim.fn.mkdir(injected, "p")
  vim.fn.writefile({}, injected .. "/main.tf")
  local buf = vim.fn.bufadd(injected .. "/main.tf")
  local problems = refused_problems("newline root", buf, events, { text.not_a_file })
  want(problems, terraform_trust.root(buf) == nil, "newline root: root " .. show(terraform_trust.root(buf)))

  local cr_dir = tmp .. "/cr\rdir"
  vim.fn.mkdir(cr_dir, "p")
  vim.fn.writefile({}, cr_dir .. "/main.tf")
  trust("allow", cr_dir)
  want(problems, terraform_trust.trust_hash(cr_dir) == "directory", "carriage return: trust " .. show(trust_lines()))
  local dirs = root_dirs(vim.lsp.config.terraformls.root_dir, vim.fn.bufadd(cr_dir .. "/main.tf"))
  want(problems, #dirs == 0, "carriage return, trusted: on_dir calls " .. show(dirs))

  local link = tmp .. "/L10e-link"
  assert(vim.uv.fs_symlink(injected, link))
  -- Named while new/ does not exist, so Neovim cannot resolve the link; then created, as :w ++p does
  local new_buf = vim.fn.bufadd(link .. "/new/main.tf")
  vim.fn.mkdir(injected .. "/new", "p")
  local new_root = terraform_trust.root(new_buf)
  want(problems, new_root == link .. "/new", "through the link: root " .. show(new_root))
  vim.list_extend(
    problems,
    refused_problems("through the link", new_buf, events, { link .. "/new", text.resolved_line_break })
  )
  return joined(problems)
end)

-- L10f: :TerraformTrust checks that the database holds the entry it wrote (the written data, not the
-- gate's policy, which allows every root without the CLI): when it does not (here vim.secure.trust
-- writes a line with a file's content hash), it warns, does not report success, and does not re-run
-- the gate, with the CLI and without it
case("L10f-post-write-check", function()
  local problems = {}
  for _, run in ipairs { { "with the CLI", bins.terraform }, { "without the CLI", bins.none } } do
    local label, path = run[1], run[2]
    local events, _, buf = terraform_setup("L10f-" .. label:gsub(" ", "-"))
    vim.env.PATH = path
    vim.fn.mkdir(vim.fn.stdpath "state", "p")
    vim.api.nvim_set_current_buf(buf)
    vim.lsp.config("terraformls", { filetypes = { "terraform" } })
    vim.lsp.enable "terraformls"
    vim.secure.trust = function(opts)
      local real = assert(vim.uv.fs_realpath(opts.path))
      write_trust { file_hash .. " " .. real }
      return true, real
    end
    local calls, undo = record_activation()
    vim.cmd "TerraformTrust"
    undo()
    want(
      problems,
      #events == 1 and is_notice(events[1], vim.log.levels.WARN, { text.not_read_back }),
      label .. ": want one WARN notice that the entry could not be read back; got " .. show(events)
    )
    want(problems, #calls == 0, label .. ": activation calls " .. show(calls))
    restore()
    begin_case()
  end
  return joined(problems)
end)

-- L10g: the command, with or without !, re-runs the gate (vim.lsp.enable) only when terraformls is
-- enabled and a root was trusted; trust_current_buffer itself returns the root and makes no vim.lsp
-- call
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

  -- { label, terraformls enabled, HOME, want a vim.lsp.enable call, command (default TerraformTrust) }
  for _, run in ipairs {
    { "enabled", true, home, true },
    { "not enabled", false, home, false },
    { "enabled, refused (home directory)", true, dir, false },
    { "enabled, bang", true, home, true, "TerraformTrust!" },
    { "enabled, bang overrides (home directory)", true, dir, true, "TerraformTrust!" },
  } do
    vim.fn.delete(trust_file())
    vim.lsp.enable("terraformls", run[2])
    vim.env.HOME = run[3]
    local calls, undo = record_activation()
    vim.cmd(run[5] or "TerraformTrust")
    undo()
    local want_calls = run[4] and { { "enable", "terraformls" } } or {}
    want(problems, vim.deep_equal(calls, want_calls), run[1] .. ": activation calls " .. show(calls))
  end
  local asked = vim.tbl_filter(function(event)
    return event.kind ~= "notify"
  end, events)
  want(problems, #asked == 0, "reads or prompts " .. show(asked))
  return joined(problems)
end)

-- L10h: :TerraformTrust! overrides a refusal the gate can honor: the home directory and a parent of
-- it the user owns, which :TerraformTrust refuses. The command that the notice's hint and the
-- refusal's hint name, run as named, trusts the root with the usual message, and the gate then
-- allows it. A world-writable root and one owned by another user stay refused, with nothing written.
case("L10h-bang-override", function()
  local events, home, home_buf = terraform_setup "L10h-home"
  local parent, parent_buf = project "L10h-parent"
  vim.fn.mkdir(parent .. "/home", "p")
  local problems = {}

  -- { label, buffer, its root, HOME, reason }
  for _, target in ipairs {
    { "home", home_buf, home, home, reasons.home },
    { "user's parent of home", parent_buf, parent, parent .. "/home", reasons.home_parent },
  } do
    local label, buf, root_dir, reason = target[1], target[2], target[3], target[5]
    vim.env.HOME = target[4]
    vim.fn.delete(trust_file())
    local texts, absent_texts = advice_texts(root_dir, reason, true)

    local before = #events
    root_dirs(vim.lsp.config.terraformls.root_dir, buf)
    local notice = events[before + 1]
    want(
      problems,
      #events == before + 1 and is_notice(notice, vim.log.levels.INFO, texts, absent_texts),
      label .. ": want one INFO notice with " .. show(texts) .. "; got " .. show(vim.list_slice(events, before + 1))
    )
    vim.list_extend(problems, refused_problems(label .. ", :TerraformTrust", buf, events, texts, absent_texts))
    local refusal = events[#events]

    for _, hinted in ipairs { { "notice", notice }, { "refusal", refusal } } do
      local event = hinted[2]
      local command = event and event.kind == "notify" and hinted_command(event.msg)
      local run = label .. ", the " .. hinted[1] .. "'s command " .. show(command)
      if not command then
        want(problems, false, run .. ": no command in " .. show(event))
      else
        vim.fn.delete(trust_file())
        vim.api.nvim_set_current_buf(buf)
        before = #events
        local ok, err = pcall(vim.cmd, command)
        local notices = vim.list_slice(events, before + 1)
        want(problems, ok, run .. ": error " .. tostring(err))
        want(
          problems,
          #notices == 1 and notices[1].level == vim.log.levels.INFO and notices[1].msg == text.allowed .. root_dir,
          run .. ": want the INFO notice " .. show(text.allowed .. root_dir) .. "; got " .. show(notices)
        )
        local lines = trust_lines()
        want(problems, vim.deep_equal(lines, { "directory " .. root_dir }), run .. ": trust database " .. show(lines))
        want(problems, terraform_trust.allowed(root_dir), run .. ": allowed(root) false")
      end
    end
  end

  -- The database still holds the parent's entry, which these refusals must leave as it is
  vim.env.HOME = home
  local open, open_buf = project "L10h-world-writable"
  assert(vim.uv.fs_chmod(open, tonumber("777", 8)))
  local foreign, foreign_buf = project "L10h-foreign"
  local uid = original.getuid()
  -- { label, buffer, its root, reason, getuid }
  for _, target in ipairs {
    { "world-writable", open_buf, open, reasons.world_writable },
    {
      "foreign-owned",
      foreign_buf,
      foreign,
      reasons.not_owned,
      function()
        return uid + 1
      end,
    },
  } do
    vim.uv.getuid = target[5] or original.getuid
    local texts, absent_texts = advice_texts(target[3], target[4], false)
    vim.list_extend(
      problems,
      refused_problems(target[1] .. ", :TerraformTrust!", target[2], events, texts, absent_texts, "TerraformTrust!")
    )
    vim.uv.getuid = original.getuid
  end
  return joined(problems)
end)

-- L10i: :TerraformTrust writes the entry for the path it checked. A file named through a link into a
-- directory literally named $EDITOR_TEST_ALIAS, before its own directory existed (as :w ++p allows),
-- keeps a name without $NAME, so it has a root, but its resolved path holds $EDITOR_TEST_ALIAS.
-- vim.secure.trust normalizes the path it is given, so it must get the root, not the resolved path:
-- the database then allows the resolved directory itself, never the one EDITOR_TEST_ALIAS names.
case("L10i-trust-write-resolved-dollar-name", function()
  local events = terraform_setup "L10i"
  local other = tmp .. "/L10i-other"
  vim.fn.mkdir(other .. "/new", "p")
  local literal = dollar_name_tree("L10i", other, false)
  local link = tmp .. "/L10i-link"
  assert(vim.uv.fs_symlink(literal, link))
  -- Named while new/ does not exist, so Neovim cannot resolve the link; then created, as :w ++p does
  local buf = vim.fn.bufadd(link .. "/new/main.tf")
  vim.fn.mkdir(literal .. "/new", "p")
  local problems = {}
  local got_root = terraform_trust.root(buf)
  want(problems, got_root == link .. "/new", "root " .. show(got_root))
  vim.fn.mkdir(vim.fn.stdpath "state", "p")
  vim.api.nvim_set_current_buf(buf)
  vim.cmd "TerraformTrust"
  local lines = trust_lines()
  want(problems, vim.deep_equal(lines, { "directory " .. literal .. "/new" }), "trust database " .. show(lines))
  want(problems, not terraform_trust.allowed(other .. "/new"), "allowed(" .. other .. "/new) true")
  want(
    problems,
    #events == 1 and is_notice(events[1], vim.log.levels.INFO, { text.allowed .. literal .. "/new" }),
    "want one INFO notice that " .. literal .. "/new is allowed; got " .. show(events)
  )
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

-- L17b: lua_ls keeps its logs, and the plugin approvals LuaLS loads without asking
-- (<logpath>/trusted), in a dir under Neovim's log dir, not in its install dir, where approvals from
-- before L17's handler may remain
case("L17b-lua_ls-logpath", function()
  load_spec "lsp"
  local cmd = (vim.lsp.config.lua_ls or {}).cmd
  local want_cmd = { "lua-language-server", "--logpath=" .. vim.fn.stdpath "log" .. "/lua_ls" }
  if not vim.deep_equal(cmd, want_cmd) then
    return "cmd " .. show(cmd) .. ", want " .. show(want_cmd)
  end
end)

-- ---------------------------------------------------------------------------
-- Cases that load settings.lua or init.lua
-- ---------------------------------------------------------------------------
-- They set global options, autocmds, keymaps, and environment that no other case should inherit,
-- so they stay at the end of the file: add new cases above this section. L15c stays last, because
-- running init.lua also enables vim.loader, prepends a scratch lazy.nvim dir to 'runtimepath', and
-- leaves settings and mappings in package.loaded. vim.loader then caches into the scratch dir, so
-- after the final vim.fn.delete(tmp, "rf") nothing may load a Lua module for the first time.

-- L15: terraform runs started from Neovim skip HashiCorp's update check (id predates L16 and L17).
case("L15-checkpoint-disabled", function()
  vim.env.CHECKPOINT_DISABLE = nil
  dofile(root .. "/lua/settings.lua")
  if vim.env.CHECKPOINT_DISABLE ~= "1" then
    return "CHECKPOINT_DISABLE = " .. show(vim.env.CHECKPOINT_DISABLE)
  end
end)

-- L15b: Go commands started from Neovim never download a toolchain, even when Neovim inherits
-- GOTOOLCHAIN=auto.
case("L15b-gotoolchain-local", function()
  vim.env.GOTOOLCHAIN = "auto"
  dofile(root .. "/lua/settings.lua")
  if vim.env.GOTOOLCHAIN ~= "local" then
    return "GOTOOLCHAIN = " .. show(vim.env.GOTOOLCHAIN)
  end
end)

-- L15c: init.lua loads settings.lua before lazy.setup, so plugins that copy Neovim's environment
-- when they first load (Mason) start with GOTOOLCHAIN=local. lazy.setup is a stub that records the
-- value; the lazy.nvim dir already exists under the scratch data dir, so init.lua never clones it
-- (and PATH holds no git). settings and mappings are cleared from package.loaded first, so
-- init.lua runs them again.
case("L15c-settings-before-lazy", function()
  vim.env.GOTOOLCHAIN = "auto"
  package.loaded.settings, package.loaded.mappings = nil, nil
  vim.fn.mkdir(vim.fn.stdpath "data" .. "/lazy/lazy.nvim", "p")
  local setup_ran, seen = false, nil
  package.loaded.lazy = {
    setup = function()
      setup_ran = true
      seen = vim.env.GOTOOLCHAIN
    end,
  }
  local ok, err = xpcall(function()
    return dofile(root .. "/init.lua")
  end, debug.traceback)
  package.loaded.lazy = nil
  if not ok then
    return "init.lua failed: " .. (tostring(err):gsub("\n%s*", " | "))
  end
  if not setup_ran then
    return "init.lua never called lazy.setup"
  end
  if seen ~= "local" then
    return "GOTOOLCHAIN when lazy.setup ran = " .. show(seen)
  end
end)

vim.fn.delete(tmp, "rf")
say("exit=" .. failed)
io.flush()
-- :cquit rather than os.exit(), which skips Neovim's exit and leaves its temp dir behind
vim.cmd.cquit { count = failed }
