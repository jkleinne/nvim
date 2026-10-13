return {
  "neovim/nvim-lspconfig",
  event = { "BufReadPre", "BufNewFile" },
  dependencies = {
    "mason-org/mason.nvim",
    "mason-org/mason-lspconfig.nvim",
  },
  config = function()
    local typescript = require "lsp_gates.typescript"
    local terraform_trust = require "lsp_gates.terraform_trust"

    -- Each config run (for example :Lazy reload) starts a new session: unanswered roots get the notice again
    terraform_trust.reset()

    -- Installed by Mason (native binaries, no npm)
    local mason_servers = {
      "gopls",
      "lua_ls",
      "sqls",
      "terraformls",
    }

    -- Installed by the system package manager (server = command it runs; one entry per line, because
    -- tests/install-script.test.sh T20 parses this table). These are Node programs; the Arch packages
    -- depend on nodejs, not npm. The commands are bare names, so each runs the first match on PATH;
    -- as lists they replace lspconfig's default lookup in root_dir/node_modules/.bin (jsonls, ts_ls,
    -- yamlls).
    -- Keep in sync with install_language_servers in nvim-install.sh.
    local system_servers = {
      bashls = { "bash-language-server", "start" },
      dockerls = { "docker-langserver", "--stdio" },
      jsonls = { "vscode-json-language-server", "--stdio" },
      pyright = { "pyright-langserver", "--stdio" },
      ts_ls = { "typescript-language-server", "--stdio" },
      yamlls = { "yaml-language-server", "--stdio" },
    }

    -- No longer used by this config (docker_language_server: see README). A leftover Mason copy from
    -- an older version must never start.
    local retired_servers = { "ansiblels", "docker_compose_language_service", "docker_language_server", "sqlls" }

    -- lsp.lua alone decides whether a system server runs. mason-lspconfig would otherwise enable any
    -- Mason-installed copy by name with lspconfig's defaults, skipping the gates below; Mason puts its
    -- bin dir first on PATH, so a Mason-only copy still runs through the gated loop.
    local not_auto_enabled = vim.list_extend(vim.tbl_keys(system_servers), retired_servers)
    table.sort(not_auto_enabled)

    local system_tsserver = typescript.system_tsserver()

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

    -- tsserver's automatic type acquisition runs npm to download @types packages, so it is off
    local ts_ls = { init_options = { disableAutomaticTypingAcquisition = true } }
    if system_tsserver then
      ts_ls.init_options.tsserver = { path = system_tsserver }
    else
      -- Never starts, not even through a manual :lsp enable: else ts_ls would load the workspace's
      -- TypeScript
      ts_ls.root_dir = function() end
    end
    vim.lsp.config("ts_ls", ts_ls)

    -- Remote schemas are never downloaded: the schema stores are off, and registerContentRequest has the
    -- server send $schema URLs to Neovim, which has no handler for them. on_init chains lspconfig's own
    -- on_init (it turns on formatting) instead of copying it, because a function is replaced, not
    -- merged. The empty-object params keep yaml-language-server from logging an ERROR on every start.
    local upstream_on_init = vim.lsp.config.yamlls and vim.lsp.config.yamlls.on_init
    vim.lsp.config("yamlls", {
      settings = {
        yaml = {
          schemaStore = { enable = false, url = "" },
          kubernetesCRDStore = { enable = false },
        },
      },
      on_init = function(client, init_result)
        if upstream_on_init then
          upstream_on_init(client, init_result)
        end
        client:notify("yaml/registerContentRequest", vim.empty_dict())
      end,
    })

    -- http(s) $schema URLs go to Neovim, which has no handler, so jsonls never downloads them; local
    -- schemas still work
    vim.lsp.config("jsonls", { init_options = { handledSchemaProtocols = { "file" } } })

    vim.lsp.config("terraformls", { root_dir = terraform_trust.root_dir })

    -- Configuration and activation are separate: every system server gets its list cmd, so a manual
    -- :lsp enable never falls back to lspconfig's node_modules/.bin lookup (a missing binary just
    -- fails to spawn), and only the ones whose command is executable are enabled (ts_ls also needs a
    -- system TypeScript), which keeps lsp.log free of spawn errors and makes vim.lsp.is_enabled reflect
    -- what is installed. Every vim.lsp.config call comes before mason_lspconfig.setup, because
    -- enabling re-fires FileType for open buffers.
    local enable = {}
    for server, cmd in pairs(system_servers) do
      vim.lsp.config(server, { cmd = cmd })
      if vim.fn.executable(cmd[1]) == 1 and (server ~= "ts_ls" or system_tsserver) then
        table.insert(enable, server)
      end
    end

    local mason_lspconfig = require "mason-lspconfig"

    mason_lspconfig.setup {
      ensure_installed = mason_servers,
      automatic_enable = { exclude = not_auto_enabled },
    }

    vim.lsp.enable(enable)

    vim.api.nvim_create_user_command(
      "TerraformTrust",
      terraform_trust.trust_current_buffer,
      { desc = "Allow terraform-ls, which runs provider plugins from .terraform, in this file's root" }
    )

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
