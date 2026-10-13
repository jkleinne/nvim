-- terraform-ls's trust gate, used by lua/plugins/lsp.lua. terraform-ls runs `terraform providers
-- schema`, which executes provider binaries from .terraform directories. When the terraform CLI is
-- installed, it starts only in roots the trust database allows (:help vim.secure.trust()) that the
-- current user owns: trust is keyed by path only, so, as with git's safe.directory rule, a
-- directory owned by someone else never counts. A root whose path has a line break never starts and
-- is never trusted, because Neovim writes trust lines without escaping. Nothing ever prompts:
-- vim.secure.read's single-key prompt can pop up asynchronously (for example after Mason finishes
-- installing terraform-ls) and be answered by whatever is typed next, so it is never called. Trust
-- comes only from :TerraformTrust or :trust. To revoke it, run `:trust ++remove <dir>`, then
-- `:lsp stop terraformls` for a client that is already running. Requiring this module has no side
-- effects.
local M = {}

M.SERVER = "terraformls"
M.COMMAND = "TerraformTrust"

-- Trust-database hashes for a directory: allowed, denied
local TRUSTED, DENIED = "directory", "!"

-- too_broad's reason for a directory owned by someone else. :trust does not help there, so the
-- messages for it do not suggest it.
local NOT_OWNED = "owned by another user"

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

-- Whether terraform-ls may start in root, given hash = M.trust_hash(root), so a caller decides
-- from one read of the database
local function allows(root, hash)
  if has_line_break(root) then
    return false
  end
  if vim.fn.executable "terraform" == 0 then
    -- No CLI, so nothing runs provider plugins
    return true
  end
  return hash == TRUSTED and owned_by_user(root)
end

-- Whether terraform-ls may start in root. trust_hash alone reads the database: vim.secure.read is
-- not consulted, because a second reader could disagree with this one and reach its prompt.
function M.allowed(root)
  return allows(root, M.trust_hash(root))
end

-- Why :TerraformTrust refuses root, or nil: trust in / or in the home directory or a parent of it
-- would cover far more than one project, anyone can create a .terraform in a world-writable
-- directory, and someone else controls a directory they own (the gate never allows it)
function M.too_broad(root)
  local real = vim.uv.fs_realpath(root) or root
  if real == "/" then
    return "the filesystem root"
  end
  local home = vim.env.HOME and vim.uv.fs_realpath(vim.env.HOME)
  if home and real == home then
    return "your home directory"
  end
  if home and vim.startswith(home .. "/", real .. "/") then
    return "a parent of your home directory"
  end
  local stat = vim.uv.fs_stat(root)
  if stat and require("bit").band(stat.mode, tonumber("002", 8)) ~= 0 then
    return "world-writable"
  end
  if not owned_by_user(root) then
    return NOT_OWNED
  end
  return nil
end

-- The notice for a root terraform-ls is off in that the database does not deny
local function off_notice(root)
  if not vim.uv.fs_stat(root) then
    return "terraform-ls is off: save the file first, then run :" .. M.COMMAND
  end
  local reason = M.too_broad(root)
  if reason == NOT_OWNED then
    return ("terraform-ls is off in %s (%s); it starts only in directories you own"):format(root, reason)
  end
  if reason then
    return ("terraform-ls is off in %s (%s); trust it on purpose with :trust %s"):format(
      root,
      reason,
      vim.fn.fnameescape(root)
    )
  end
  return "terraform-ls is off in "
    .. root
    .. ": it would run provider plugins from .terraform directories in and below it. "
    .. "Run :"
    .. M.COMMAND
    .. " there to allow it."
end

-- terraformls's root_dir: hands Neovim the root only when it is allowed, so terraform-ls never
-- starts anywhere else. A root the database does not allow or deny gets a notice, once per session,
-- instead of a prompt; a denied root gets none.
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

-- Allows the current file buffer's root in the trust database, unless too_broad refuses it, and
-- checks that the gate reads the entry back. Returns the root, or nil when nothing was allowed.
function M.trust_current_buffer()
  local warn = vim.log.levels.WARN
  local root = M.root(0)
  if not root then
    vim.notify(M.COMMAND .. ": run it from a buffer that shows a file whose path has no line breaks", warn)
    return nil
  end
  if not vim.uv.fs_stat(root) then
    vim.notify(("%s: %s does not exist yet; save the file first"):format(M.COMMAND, root), warn)
    return nil
  end
  local reason = M.too_broad(root)
  if reason == NOT_OWNED then
    vim.notify(
      ("%s: not trusting %s (%s); terraform-ls starts only in directories you own"):format(M.COMMAND, root, reason),
      warn
    )
    return nil
  end
  if reason then
    vim.notify(
      ("%s: not trusting %s (%s). If you really mean it, run :trust %s"):format(
        M.COMMAND,
        root,
        reason,
        vim.fn.fnameescape(root)
      ),
      warn
    )
    return nil
  end
  local ok, path = vim.secure.trust { action = "allow", path = root }
  if not ok then
    vim.notify(M.COMMAND .. ": " .. path, vim.log.levels.ERROR)
    return nil
  end
  if not M.allowed(root) then
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
