-- terraform-ls's trust gate, used by lua/plugins/lsp.lua. terraform-ls runs `terraform providers
-- schema`, which executes provider binaries from .terraform directories. When the terraform CLI is
-- installed, it starts only in roots the trust database allows (:help vim.secure.trust()) that the
-- current user owns and others cannot write: trust is keyed by path only, so, as with git's
-- safe.directory rule, a directory someone else owns or anyone can write never counts. Neovim writes
-- trust lines without escaping, so a root whose path has a line break never starts, and
-- :TerraformTrust never trusts a root whose path or resolved path has one. Nothing ever prompts:
-- vim.secure.read's single-key prompt can pop up asynchronously (for example after Mason finishes
-- installing terraform-ls) and be answered by whatever is typed next, so it is never called. Trust
-- comes only from :TerraformTrust or :trust. To revoke it, run `:trust ++remove <dir>`, then
-- `:lsp stop terraformls` for a client that is already running. Requiring this module has no side
-- effects.
local M = {}

M.SERVER = "terraformls"
M.COMMAND = "TerraformTrust"

-- Why M.refusal refuses a root, as the messages name it
M.REASONS = {
  filesystem_root = "the filesystem root",
  home = "your home directory",
  home_parent = "a parent of your home directory",
  world_writable = "world-writable",
  not_owned = "owned by another user",
}

-- Trust-database hashes for a directory: allowed, denied
local TRUSTED, DENIED = "directory", "!"

-- Roots told about this session, so each gets the notice once
local notified_roots = {}

-- Whether path has a line break. runtime secure.lua writes "<hash> <path>" lines without escaping,
-- so trusting such a path would add lines of its own choosing.
local function has_line_break(path)
  return path:find "[\r\n]" ~= nil
end

-- Whether the current user owns dir. false when dir cannot be stat'ed.
local function owned_by_user(dir)
  local stat = vim.uv.fs_stat(dir)
  return stat ~= nil and stat.uid == vim.uv.getuid()
end

-- Whether anyone may write dir (anyone could then create a .terraform in it). false when dir
-- cannot be stat'ed.
local function world_writable(dir)
  local stat = vim.uv.fs_stat(dir)
  return stat ~= nil and require("bit").band(stat.mode, tonumber("002", 8)) ~= 0
end

-- The current user's home directory, resolved, as $HOME names it and as the passwd entry does (they
-- can differ, and HOME can be unset or missing). Skips one that cannot be resolved.
local function home_dirs()
  local dirs = {}
  local function add(dir)
    local real = dir and vim.uv.fs_realpath(dir)
    if real then
      dirs[#dirs + 1] = real
    end
  end
  add(vim.env.HOME)
  add((vim.uv.os_get_passwd() or {}).homedir)
  return dirs
end

-- The hash of the last trust-database line for dir: "directory" (allowed), "!" (denied), or a
-- file's content hash. nil when the database has no line for dir or cannot be read, or dir does not
-- exist. Mirrors runtime secure.lua's keying: the path is normalized, then resolved with realpath,
-- and the last line for a path wins (secure.lua reads the lines into a table keyed by path).
function M.trust_hash(dir)
  local path = vim.uv.fs_realpath(vim.fs.normalize(dir))
  if not path then
    return nil
  end
  local f = io.open(vim.fn.stdpath "state" .. "/trust", "r")
  if not f then
    return nil
  end
  local hash
  for line in f:lines() do
    local line_hash, file = line:match "^(%S+) (.+)$"
    if file == path then
      hash = line_hash
    end
  end
  f:close()
  return hash
end

-- terraform-ls's root: the nearest ancestor with .terraform, else the nearest with .git (all
-- ancestors are searched for .terraform first, as lspconfig's terraformls root_markers are), else
-- the file's directory. nil unless bufnr is a file buffer (an unnamed buffer has no file to start
-- from, and vim.fs.root starts from the cwd for a buffer with a 'buftype'), and nil for a root
-- whose path has a line break.
function M.root(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" or vim.bo[bufnr].buftype ~= "" then
    return nil
  end
  local root = vim.fs.root(bufnr, { ".terraform", ".git" }) or vim.fs.dirname(name)
  if has_line_break(root) then
    return nil
  end
  return root
end

-- Whether terraform-ls may start in root (from M.root, so without line breaks), given hash =
-- M.trust_hash(root), so a caller decides from one read of the database
local function allows(root, hash)
  if vim.fn.executable "terraform" == 0 then
    -- No CLI, so nothing runs provider plugins
    return true
  end
  return hash == TRUSTED and owned_by_user(root) and not world_writable(root)
end

-- Whether terraform-ls may start in root (from M.root). trust_hash alone reads the database:
-- vim.secure.read is not consulted, because a second reader could disagree with this one and reach
-- its prompt.
function M.allowed(root)
  return allows(root, M.trust_hash(root))
end

-- Why :TerraformTrust refuses root, or nil: trust in / or in the home directory or a parent of it
-- would cover far more than one project, anyone can create a .terraform in a world-writable
-- directory, and someone else controls a directory they own. Returns { reason = <M.REASONS text>,
-- overridable = <bool> }: overridable when :trust <root> would make the gate allow it, that is,
-- when the user owns root and others cannot write it.
function M.refusal(root)
  local real = vim.uv.fs_realpath(root) or root
  local homes = home_dirs()
  local function is_home_parent()
    return vim.iter(homes):any(function(home)
      return vim.startswith(home, real .. "/")
    end)
  end
  local reason
  if real == "/" then
    reason = M.REASONS.filesystem_root
  elseif vim.list_contains(homes, real) then
    reason = M.REASONS.home
  elseif is_home_parent() then
    reason = M.REASONS.home_parent
  elseif world_writable(root) then
    reason = M.REASONS.world_writable
  elseif not owned_by_user(root) then
    reason = M.REASONS.not_owned
  end
  if not reason then
    return nil
  end
  return { reason = reason, overridable = owned_by_user(root) and not world_writable(root) }
end

-- "<root> (<reason>); <what the user can do>" for a refusal record. :trust is suggested only where
-- the gate would honor it.
local function refusal_text(root, refusal)
  local hint = refusal.overridable and ("trust it on purpose with :trust " .. vim.fn.fnameescape(root))
    or "terraform-ls starts only in directories you own that others cannot write"
  return ("%s (%s); %s"):format(root, refusal.reason, hint)
end

-- The notice for a root terraform-ls is off in that the database does not deny
local function off_notice(root)
  if not vim.uv.fs_stat(root) then
    return "terraform-ls is off: save the file first, then run :" .. M.COMMAND
  end
  local refusal = M.refusal(root)
  if refusal then
    return "terraform-ls is off in " .. refusal_text(root, refusal)
  end
  return "terraform-ls is off in "
    .. root
    .. ": it would run provider plugins from .terraform directories in and below it. "
    .. "Run :"
    .. M.COMMAND
    .. " there to allow it."
end

-- terraformls's root_dir: hands Neovim the root only when it is allowed, so terraform-ls never
-- starts anywhere else. A root the database does not deny gets a notice, once per session, instead
-- of a prompt; a denied root gets none.
function M.root_dir(bufnr, on_dir)
  local root = M.root(bufnr)
  if not root then
    return
  end
  local hash = M.trust_hash(root)
  if allows(root, hash) then
    on_dir(root)
    return
  end
  if hash == DENIED or notified_roots[root] then
    return
  end
  notified_roots[root] = true
  vim.notify(off_notice(root), vim.log.levels.INFO)
end

-- Starts a new session of notices: every root not allowed gets the notice again
function M.reset()
  notified_roots = {}
end

-- Allows the current file buffer's root in the trust database, unless M.refusal refuses it, and
-- checks that the database holds the entry. Returns the root, or nil when nothing was allowed.
function M.trust_current_buffer()
  local warn = vim.log.levels.WARN
  local root = M.root(0)
  if not root then
    vim.notify(M.COMMAND .. ": run it from a buffer that shows a file whose path has no line breaks", warn)
    return nil
  end
  local real = vim.uv.fs_realpath(root)
  if not real then
    vim.notify(("%s: %s does not exist yet; save the file first"):format(M.COMMAND, root), warn)
    return nil
  end
  -- vim.secure.trust writes the resolved path, which can have a line break where root has none: a
  -- file :w ++p wrote into a new directory through a symlink keeps the link's path as its name
  if has_line_break(real) then
    vim.notify(("%s: not trusting %s: its resolved path has a line break"):format(M.COMMAND, root), warn)
    return nil
  end
  local refusal = M.refusal(root)
  if refusal then
    vim.notify(("%s: not trusting %s"):format(M.COMMAND, refusal_text(root, refusal)), warn)
    return nil
  end
  local ok, path = vim.secure.trust { action = "allow", path = root }
  if not ok then
    vim.notify(M.COMMAND .. ": " .. path, vim.log.levels.ERROR)
    return nil
  end
  -- Checks the written data, not the policy (M.allowed is true for any root without the CLI)
  if M.trust_hash(root) ~= TRUSTED then
    vim.notify(M.COMMAND .. ": wrote the trust entry but could not read it back (trust database format changed?)", warn)
    return nil
  end
  vim.notify("terraform-ls allowed in " .. path, vim.log.levels.INFO)
  return root
end

-- Registers :TerraformTrust. After allowing a root it re-runs the gate for open buffers, when
-- terraformls is enabled; when it is not enabled yet, mason-lspconfig enables it after installing it.
function M.create_command()
  vim.api.nvim_create_user_command(M.COMMAND, function()
    local root = M.trust_current_buffer()
    if root and vim.lsp.is_enabled(M.SERVER) then
      vim.lsp.enable(M.SERVER)
    end
  end, { desc = "Allow terraform-ls, which runs provider plugins from .terraform, in this file's root" })
end

return M
