-- The language servers this config sets up. Data only: read by lua/plugins/lsp.lua, and by
-- tests/install-script.test.sh T20 through `nvim --clean -l`. Keep `system` in sync with
-- install_language_servers in nvim-install.sh and the README's pacman command.
return {
  -- Installed by Mason (native binaries, no npm)
  mason = {
    "gopls",
    "lua_ls",
    "sqls",
    "terraformls",
  },

  -- Installed by the system package manager (server = command it runs). These are Node programs;
  -- the Arch packages depend on nodejs, not npm. The commands are bare names, so each runs the first
  -- match on PATH.
  system = {
    bashls = { "bash-language-server", "start" },
    dockerls = { "docker-langserver", "--stdio" },
    jsonls = { "vscode-json-language-server", "--stdio" },
    pyright = { "pyright-langserver", "--stdio" },
    ts_ls = { "typescript-language-server", "--stdio" },
    yamlls = { "yaml-language-server", "--stdio" },
  },

  -- No longer used by this config (docker_language_server: see README). A leftover Mason copy from
  -- an older version must never start.
  retired = { "ansiblels", "docker_compose_language_service", "docker_language_server", "sqlls" },
}
