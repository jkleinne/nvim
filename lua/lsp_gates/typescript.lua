-- ts_ls's TypeScript policy, used by lua/plugins/lsp.lua. typescript-language-server ignores a
-- tsserver path that is not a TypeScript package's tsserver.js and then loads the workspace's own
-- TypeScript, so only such a file counts. Requiring this module has no side effects.
local M = {}

M.SERVER = "ts_ls"

-- Arch's typescript package (a dependency of typescript-language-server). A field, so tests can
-- point it at a scratch package.
M.ARCH_TSSERVER = "/usr/lib/node_modules/typescript/lib/tsserver.js"

-- Whether this session showed the refusal notice
local refusal_notified = false

-- js with symlinks resolved, when that is lib/tsserver.js of a package whose package.json names
-- typescript and has a non-empty string version (typescript-language-server treats a null or ""
-- version as invalid), else nil. Resolved first because typescript-language-server resolves it
-- before it reads the package.json two levels above. Never raises: a package.json that is a
-- directory or cannot be read makes no package.
function M.package_tsserver(js)
  js = vim.uv.fs_realpath(js)
  if not js then
    return nil
  end
  local package_json = vim.fs.dirname(vim.fs.dirname(js)) .. "/package.json"
  local ok, meta = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(package_json), "\n"))
  end)
  if
    ok
    and type(meta) == "table"
    and meta.name == "typescript"
    and type(meta.version) == "string"
    and meta.version ~= ""
  then
    return js
  end
  return nil
end

-- Arch's TypeScript (M.ARCH_TSSERVER), else the TypeScript package the tsserver on PATH belongs to
-- (a shim or a wrapper script belongs to none). nil when there is no system TypeScript.
function M.system_tsserver()
  local arch = M.package_tsserver(M.ARCH_TSSERVER)
  if arch then
    return arch
  end
  local bin = vim.fn.exepath "tsserver"
  local real = bin ~= "" and vim.uv.fs_realpath(bin) or nil
  local package_root = real and vim.fs.root(real, "package.json")
  return package_root and M.package_tsserver(package_root .. "/lib/tsserver.js") or nil
end

-- ts_ls's root_dir without a system TypeScript: it never hands Neovim a root, so ts_ls never starts,
-- even through :lsp enable ts_ls, and the first call each session says why
function M.refusing_root_dir()
  if refusal_notified then
    return
  end
  refusal_notified = true
  vim.notify(
    "ts_ls is off: no system TypeScript found (Arch: the typescript package; elsewhere your distro's "
      .. "TypeScript package, which provides tsserver). Without one, ts_ls would load a repo's own TypeScript.",
    vim.log.levels.INFO
  )
end

-- ts_ls's whole configuration for system_tsserver (M.system_tsserver()'s answer), and whether to
-- enable ts_ls. upstream_root_dir is the root_dir configured before this one (lspconfig's), or nil.
-- tsserver's automatic type acquisition runs npm to download @types packages, so it is always off.
function M.ts_ls_config(system_tsserver, upstream_root_dir)
  local init_options = { disableAutomaticTypingAcquisition = true }
  if not system_tsserver then
    return { init_options = init_options, root_dir = M.refusing_root_dir }, false
  end
  init_options.tsserver = { path = system_tsserver }
  -- The package is checked again whenever a buffer asks for a root: once it is gone (say,
  -- uninstalled mid-session), typescript-language-server would load the workspace's TypeScript
  local function root_dir(bufnr, on_dir)
    if not M.package_tsserver(system_tsserver) then
      M.refusing_root_dir()
      return
    end
    if upstream_root_dir then
      upstream_root_dir(bufnr, on_dir)
      return
    end
    -- Without lspconfig's (as under --clean), the nearest project marker
    local root = vim.fs.root(bufnr, { "tsconfig.json", "jsconfig.json", "package.json", ".git" })
    if root then
      on_dir(root)
    end
  end
  return { init_options = init_options, root_dir = root_dir }, true
end

-- Starts a new session: the refusal notice shows again
function M.reset()
  refusal_notified = false
end

return M
