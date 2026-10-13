-- ts_ls's TypeScript gate, used by lua/plugins/lsp.lua. typescript-language-server ignores a tsserver
-- path that is not a TypeScript package's tsserver.js and then loads the workspace's own TypeScript,
-- so only such a file counts. Requiring this module has no side effects.
local M = {}

-- Arch's typescript package (a dependency of typescript-language-server). A field, so tests can
-- point it at a scratch package.
M.ARCH_TSSERVER = "/usr/lib/node_modules/typescript/lib/tsserver.js"

-- js when it is lib/tsserver.js of a package whose package.json names typescript and has a
-- non-empty string version (typescript-language-server treats a null or "" version as invalid),
-- else nil
function M.package_tsserver(js)
  local package_json = vim.fs.dirname(vim.fs.dirname(js)) .. "/package.json"
  if not vim.uv.fs_stat(js) or not vim.uv.fs_stat(package_json) then
    return nil
  end
  local ok, meta = pcall(vim.json.decode, table.concat(vim.fn.readfile(package_json), "\n"))
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

return M
