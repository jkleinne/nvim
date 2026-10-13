-- terraform-ls's trust gate, used by lua/plugins/lsp.lua. terraform-ls runs `terraform providers
-- schema`, which executes provider binaries from .terraform directories. When the terraform CLI is
-- installed, it starts only in roots the trust database allows (:help vim.secure.trust()). Nothing
-- ever prompts: vim.secure.read's single-key prompt can pop up asynchronously (for example after
-- Mason finishes installing terraform-ls) and be answered by whatever is typed next, so it is never
-- called. Trust comes only from :TerraformTrust or :trust. To revoke it, run `:trust ++remove <dir>`,
-- then `:lsp stop terraformls` for a client that is already running. Requiring this module has no
-- side effects.
local M = {}

-- Roots told about this session, so each gets the notice once
local notified_roots = {}

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
-- the file's directory. nil unless bufnr is a file buffer: an unnamed buffer has no file to start
-- from, and vim.fs.root starts from the cwd for a buffer with a 'buftype'.
function M.root(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" or vim.bo[bufnr].buftype ~= "" then
    return nil
  end
  return vim.fs.root(bufnr, { ".terraform", ".git" }) or vim.fs.dirname(name)
end

-- Whether terraform-ls may start in root. trust_hash alone decides: vim.secure.read is not
-- consulted, because a second reader could disagree with this one and reach its prompt.
function M.allowed(root)
  if vim.fn.executable "terraform" == 0 then
    -- No CLI, so nothing runs provider plugins
    return true
  end
  return M.trust_hash(root) == "directory"
end

-- terraformls's root_dir: hands Neovim the root only when it is allowed, so terraform-ls never
-- starts anywhere else. A root the database does not allow or deny gets a notice, once per session,
-- instead of a prompt; a denied root gets none.
function M.root_dir(bufnr, on_dir)
  local root = M.root(bufnr)
  if not root then
    return
  end
  if M.allowed(root) then
    on_dir(root)
    return
  end
  if M.trust_hash(root) ~= "!" and not notified_roots[root] then
    notified_roots[root] = true
    vim.notify(
      "terraform-ls is off in "
        .. root
        .. ": it would run provider plugins from .terraform directories in and below it. "
        .. "Run :TerraformTrust there to allow it.",
      vim.log.levels.INFO
    )
  end
end

-- Starts a new session of notices: every root not allowed gets the notice again
function M.reset()
  notified_roots = {}
end

-- Why trusting dir would cover far more than one project, or nil: the filesystem root, the home
-- directory, or a world-writable directory (anyone can create a .terraform there)
local function broad_root(dir)
  local real = vim.uv.fs_realpath(dir) or dir
  if real == "/" then
    return "the filesystem root"
  end
  if vim.env.HOME and real == vim.uv.fs_realpath(vim.env.HOME) then
    return "your home directory"
  end
  local stat = vim.uv.fs_stat(dir)
  if stat and require("bit").band(stat.mode, tonumber("002", 8)) ~= 0 then
    return "world-writable"
  end
  return nil
end

-- :TerraformTrust: allows the current file buffer's root in the trust database, then re-runs the gate
function M.trust_current_buffer()
  local root = M.root(0)
  if not root then
    vim.notify("TerraformTrust: run it from a buffer that shows a file", vim.log.levels.WARN)
    return
  end
  local reason = broad_root(root)
  if reason then
    vim.notify(
      ("TerraformTrust: not trusting %s (%s). If you really mean it, run :trust %s"):format(
        root,
        reason,
        vim.fn.fnameescape(root)
      ),
      vim.log.levels.WARN
    )
    return
  end
  local ok, path = vim.secure.trust { action = "allow", path = root }
  if not ok then
    vim.notify("TerraformTrust: " .. path, vim.log.levels.ERROR)
    return
  end
  vim.notify("terraform-ls allowed in " .. path, vim.log.levels.INFO)
  -- Re-runs the gate for open buffers. When terraformls is not enabled yet, mason-lspconfig enables
  -- it after installing it.
  if vim.lsp.is_enabled "terraformls" then
    vim.lsp.enable "terraformls"
  end
end

return M
