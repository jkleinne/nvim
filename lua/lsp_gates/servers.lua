-- The language servers this config sets up. Data only: read by lua/plugins/lsp.lua, and by
-- tests/install-script.test.sh through `nvim --clean -l tests/lib/system-servers.lua`. Keep in
-- sync: `system` with install_language_servers (pacman) in nvim-install.sh, the README's pacman command,
-- and that test; `fallbacks` with install_language_servers (dnf), the README's Fedora command, and
-- that test; every list with the independent copy in tests/editor-config.test.lua, which compares them.
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

  -- Stand-ins from the system package manager for a system server a distro does not package (Fedora
  -- has no pyright and packages python-lsp-server): server = { the server it replaces, the command it
  -- runs }. lsp.lua enables one only when the server it replaces is not enabled. The command is a bare
  -- name, so it runs the first match on PATH, like the system servers' commands.
  fallbacks = {
    pylsp = { replaces = "pyright", cmd = { "pylsp" } },
  },

  -- No longer used by this config (docker_language_server: see README). A leftover Mason copy from
  -- an older version must never start.
  retired = { "ansiblels", "docker_compose_language_service", "docker_language_server", "sqlls" },

  -- The known lspconfig servers that run repo-supplied code with tools this config installs or
  -- trusts: tflint plugins named in a repo's .tflint.hcl (tflint), a repo's .golangci.yml
  -- (golangci_lint_ls), terraform providers (terraform_lsp, tofu_ls), and a repo's Python modules
  -- through `python -m` from the repo directory (esbonio, tvm_ffi_navigator; Python comes with this
  -- config's linters). They never start, not even with a bare :lsp enable.
  never = { "esbonio", "golangci_lint_ls", "terraform_lsp", "tflint", "tofu_ls", "tvm_ffi_navigator" },
}
