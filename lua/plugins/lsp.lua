return {
  "neovim/nvim-lspconfig",
  lazy = false,
  dependencies = {
    "williamboman/mason.nvim",
    "williamboman/mason-lspconfig.nvim",
  },
  config = function()
    local mason_lspconfig = require("mason-lspconfig")

    mason_lspconfig.setup({
      ensure_installed = {
        "bashls", "dockerls", "docker_compose_language_service", 
        "gopls", "ts_ls", "jsonls", "lua_ls", "yamlls"
      },
      automatic_installation = true,
    })

    local lspconfig = require("lspconfig")
    local cmp_nvim_lsp = require("cmp_nvim_lsp")

    local servers = { "pyright", "ts_ls", "lua_ls", "gopls" }

    local capabilities = cmp_nvim_lsp.default_capabilities()

    local on_attach = function(client, bufnr)

    local opts = { noremap=true, silent=true, buffer=bufnr }

    local keymap = vim.keymap.set

    keymap('n', 'gd', vim.lsp.buf.definition, opts)
    keymap('n', 'K', vim.lsp.buf.hover, opts)
    keymap('n', 'gi', vim.lsp.buf.implementation, opts)
    keymap('n', '<C-k>', vim.lsp.buf.signature_help, opts)
    keymap('n', '<leader>wa', vim.lsp.buf.add_workspace_folder, opts)
    keymap('n', '<leader>wr', vim.lsp.buf.remove_workspace_folder, opts)
    keymap('n', '<leader>wl', function()
      print(vim.inspect(vim.lsp.buf.list_workspace_folders()))
    end, opts)
    keymap('n', '<leader>D', vim.lsp.buf.type_definition, opts)
    keymap('n', '<leader>rn', vim.lsp.buf.rename, opts)
    keymap('n', '<leader>ca', vim.lsp.buf.code_action, opts)
    keymap('n', 'gr', vim.lsp.buf.references, opts)
    keymap('n', '<leader>f', function()
      vim.lsp.buf.format { async = true }
    end, opts)
  end

  -- Setup each LSP server
  for _, lsp in ipairs(servers) do
    lspconfig[lsp].setup {
      on_attach = on_attach,
      capabilities = capabilities,
      settings = {},
    }
  end

  lspconfig.lua_ls.setup {
    on_attach = on_attach,
    capabilities = capabilities,
    settings = {
      Lua = {
        diagnostics = {
          globals = { "vim" },
        },
        workspace = {
          library = vim.api.nvim_get_runtime_file("", true),
          checkThirdParty = false,
        },
        telemetry = {
          enable = false,
        },
      },
    },
  }
end,
}
