-- Prints the command of each system server in lua/lsp_gates/servers.lua (the first string of its
-- `system` entry), one per line, sorted. T20 in tests/install-script.test.sh runs it as
--   nvim --clean --headless -l tests/lib/system-servers.lua
-- with scratch XDG dirs. --clean leaves this config off 'runtimepath', so package.path points at the
-- repo's lua/ directory.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:gsub("^@", ""), ":p:h:h:h")
package.path = root .. "/lua/?.lua;" .. package.path
local bins = {}
for _, cmd in pairs(require("lsp_gates.servers").system) do
  table.insert(bins, cmd[1])
end
table.sort(bins)
-- print() in -l mode defers the newline to the next message
io.write(table.concat(bins, "\n"), "\n")
