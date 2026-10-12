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

    -- Installed by the system package manager (server = binary it provides).
    -- These are Node programs; the Arch packages depend on nodejs, not npm:
    -- bash-language-server, vscode-json-languageserver, pyright,
    -- typescript-language-server, yaml-language-server
    local system_servers = {
      bashls = "bash-language-server",
      jsonls = "vscode-json-language-server",
      pyright = "pyright-langserver",
      ts_ls = "typescript-language-server",
      yamlls = "yaml-language-server",
    }

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

    local mason_lspconfig = require "mason-lspconfig"

    mason_lspconfig.setup {
      ensure_installed = mason_servers,
      automatic_enable = true,
    }

    -- Enable a system server only when its binary is installed. jsonls, ts_ls and
    -- yamlls define cmd as a function, so Neovim cannot skip them quietly on its own.
    for server, bin in pairs(system_servers) do
      if vim.fn.executable(bin) == 1 then
        vim.lsp.enable(server)
      end
    end

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
