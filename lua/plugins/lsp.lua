return {
  "neovim/nvim-lspconfig",
  event = { "BufReadPre", "BufNewFile" },
  dependencies = {
    "mason-org/mason.nvim",
    "mason-org/mason-lspconfig.nvim",
  },
  config = function()
    -- Installed by Mason (native binaries, no npm)
    local mason_servers = {
      "docker_language_server",
      "gopls",
      "lua_ls",
      "sqls",
      "terraformls",
    }

    -- Installed by the system package manager (server = command it runs). These are Node programs;
    -- the Arch packages depend on nodejs, not npm. Each command is pinned to the system binary so a
    -- repo's node_modules/.bin copy never runs, and the server is enabled only when that binary exists.
    -- Keep in sync with install_language_servers in nvim-install.sh.
    local system_servers = {
      bashls = { "bash-language-server", "start" },
      jsonls = { "vscode-json-language-server", "--stdio" },
      pyright = { "pyright-langserver", "--stdio" },
      ts_ls = { "typescript-language-server", "--stdio" },
      yamlls = { "yaml-language-server", "--stdio" },
    }

    -- Arch's typescript package. Without this, ts_ls loads a repo's own node_modules/typescript.
    local system_tsserver = "/usr/lib/node_modules/typescript/lib/tsserver.js"

    local capabilities = require("blink.cmp").get_lsp_capabilities()

    vim.lsp.config("*", {
      capabilities = capabilities,
    })

    vim.lsp.config("lua_ls", {
      settings = {
        Lua = {
          diagnostics = {
            globals = { "vim" },
          },
          telemetry = {
            enable = false,
          },
        },
      },
    })

    -- docker-language-server sends telemetry by default; keep it off like lua_ls
    vim.lsp.config("docker_language_server", {
      init_options = { telemetry = "off" },
      settings = { docker = { lsp = { telemetry = "off" } } },
    })

    if vim.uv.fs_stat(system_tsserver) then
      vim.lsp.config("ts_ls", { init_options = { tsserver = { path = system_tsserver } } })
    end

    local mason_lspconfig = require "mason-lspconfig"

    mason_lspconfig.setup {
      ensure_installed = mason_servers,
      automatic_enable = true,
    }

    local available = {}
    for server, cmd in pairs(system_servers) do
      if vim.fn.executable(cmd[1]) == 1 then
        vim.lsp.config(server, { cmd = cmd })
        table.insert(available, server)
      end
    end
    vim.lsp.enable(available)

    -- Set keymaps when an LSP attaches to a buffer
    vim.api.nvim_create_autocmd("LspAttach", {
      callback = function(args)
        local bufnr = args.buf
        local opts = { noremap = true, silent = true, buffer = bufnr }
        local keymap = vim.keymap.set

        keymap("n", "gl", vim.diagnostic.open_float, opts)
        keymap("n", "[d", function()
          vim.diagnostic.jump { count = -1, float = true }
        end, opts)
        keymap("n", "]d", function()
          vim.diagnostic.jump { count = 1, float = true }
        end, opts)
        keymap("n", "<leader>q", vim.diagnostic.setloclist, opts)

        keymap("n", "gd", vim.lsp.buf.definition, opts)
        keymap("n", "K", vim.lsp.buf.hover, opts)
        keymap("n", "gi", vim.lsp.buf.implementation, opts)
        keymap("n", "<C-k>", vim.lsp.buf.signature_help, opts)
        keymap("n", "<leader>wa", vim.lsp.buf.add_workspace_folder, opts)
        keymap("n", "<leader>wr", vim.lsp.buf.remove_workspace_folder, opts)
        keymap("n", "<leader>wl", function()
          print(vim.inspect(vim.lsp.buf.list_workspace_folders()))
        end, opts)
        keymap("n", "<leader>D", vim.lsp.buf.type_definition, opts)
        keymap("n", "<leader>rn", vim.lsp.buf.rename, opts)
        keymap("n", "<leader>ca", vim.lsp.buf.code_action, opts)
        keymap("n", "gr", vim.lsp.buf.references, opts)
      end,
    })
  end,
}
