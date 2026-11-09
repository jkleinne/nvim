-- Prints the server inventory in lua/lsp_gates/servers.lua for T20 in tests/install-script.test.sh:
--   nvim --clean --headless -l tests/lib/system-servers.lua [table [keys]]
-- with scratch XDG dirs. `table` is system (default) or fallbacks. Without `keys`, each line is a
-- system server's command (the first string of its entry), or a fallback's "name replaces command";
-- with the word `keys`, each line is a server name. Lines are sorted. Any other table, any other
-- second argument, and any third argument is an error, which nvim -l reports on stderr and exits 1
-- for. --clean leaves this config off 'runtimepath', so package.path points at the repo's lua/
-- directory.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:gsub("^@", ""), ":p:h:h:h")
package.path = root .. "/lua/?.lua;" .. package.path

-- One line per entry of each table this prints, by table name
local LINE_FORMATS = {
  system = function(_, entry)
    return entry[1]
  end,
  fallbacks = function(name, entry)
    return ("%s %s %s"):format(name, entry.replaces, entry.cmd[1])
  end,
}
local KEYS_ARGUMENT = "keys"

local table_name, mode = arg[1] or "system", arg[2]
local line_format = LINE_FORMATS[table_name]
if line_format == nil then
  local table_names = vim.tbl_keys(LINE_FORMATS)
  table.sort(table_names)
  error(("system-servers.lua: unknown table %q (expected %s)"):format(table_name, table.concat(table_names, " or ")), 0)
end
if mode ~= nil and mode ~= KEYS_ARGUMENT then
  error(("system-servers.lua: unknown second argument %q (expected %s)"):format(mode, KEYS_ARGUMENT), 0)
end
if arg[3] ~= nil then
  error(("system-servers.lua: unexpected third argument %q"):format(arg[3]), 0)
end
local inventory = require("lsp_gates.servers")[table_name]
if type(inventory) ~= "table" then
  error(("system-servers.lua: lsp_gates.servers has no %q table"):format(table_name), 0)
end
local lines = {}
for name, entry in pairs(inventory) do
  lines[#lines + 1] = mode == KEYS_ARGUMENT and name or line_format(name, entry)
end
table.sort(lines)
-- print() in -l mode defers the newline to the next message
io.write(table.concat(lines, "\n"), "\n")
