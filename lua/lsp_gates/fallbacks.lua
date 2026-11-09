-- The choice of which fallbacks run, used by lua/plugins/lsp.lua. A fallback (servers.fallbacks)
-- stands in for a system server a distro does not package. Requiring this module has no side effects.
local M = {}

-- The fallbacks to enable (chosen) and the ones to disable (passed_over), as two sorted lists of
-- names. A fallback is chosen when is_executable(binary) holds for the first word of its command and
-- the server it replaces is not in enabled, the system servers that will be enabled; every other one
-- is passed over. fallbacks has the shape of servers.fallbacks. The gate reads the primary's enable
-- result, not PATH, because what matters is whether the primary will run: a primary that is present
-- but gated off lets its fallback run, and one that is enabled never runs beside its fallback. The
-- caller passes is_executable in, so this module never looks at PATH and can be tested without stub
-- commands. The lists are sorted so they do not depend on the order pairs visits fallbacks in.
-- Neither fallbacks nor enabled changes.
function M.choose(fallbacks, enabled, is_executable)
  local chosen, passed_over = {}, {}
  for name, spec in pairs(fallbacks) do
    if is_executable(spec.cmd[1]) and not vim.list_contains(enabled, spec.replaces) then
      table.insert(chosen, name)
    else
      table.insert(passed_over, name)
    end
  end
  table.sort(chosen)
  table.sort(passed_over)
  return chosen, passed_over
end

return M
