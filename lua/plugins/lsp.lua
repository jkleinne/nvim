-- typescript-language-server ignores a tsserver path that is not a TypeScript package's tsserver.js and then
-- loads the workspace's own TypeScript, so only such a file counts
local function typescript_tsserver(js)
  local package_json = vim.fs.dirname(vim.fs.dirname(js)) .. "/package.json"
  if not vim.uv.fs_stat(js) or not vim.uv.fs_stat(package_json) then
    return nil
  end
  local ok, meta = pcall(vim.json.decode, table.concat(vim.fn.readfile(package_json), "\n"))
  if ok and type(meta) == "table" and meta.name == "typescript" and meta.version then
    return js
  end
  return nil
end

-- Arch's typescript package, else the TypeScript package the tsserver on PATH belongs to (a shim or a wrapper
-- script belongs to none). nil when there is no system TypeScript.
local function system_tsserver_path()
  local arch = typescript_tsserver "/usr/lib/node_modules/typescript/lib/tsserver.js"
  if arch then
    return arch
  end
  local bin = vim.fn.exepath "tsserver"
  local real = bin ~= "" and vim.uv.fs_realpath(bin) or nil
  local package_root = real and vim.fs.root(real, "package.json")
  return package_root and typescript_tsserver(package_root .. "/lib/tsserver.js") or nil
end

-- terraform-ls runs `terraform providers schema`, which executes provider binaries from .terraform
-- directories. When the terraform CLI is installed, it starts only in roots the trust database
-- allows (:help vim.secure.read()). Nothing ever prompts: vim.secure.read's single-key prompt can
-- pop up asynchronously (for example after Mason finishes installing terraform-ls) and be answered
-- by whatever is typed next. Trust comes only from :TerraformTrust or :trust. To revoke it, run
-- `:trust ++remove <dir>`, then `:lsp stop terraformls` for a client that is already running.

-- Roots told about this session, so each gets the notice once
local notified_roots = {}

-- Whether the trust database has a line for dir (format: runtime/lua/vim/secure.lua). This decides
-- only whether vim.secure.read may be called, since it prompts for unanswered paths; an unreadable
-- or reformatted database counts as unanswered, which keeps terraform-ls off (fail closed).
local function trust_answered(dir)
  local path = vim.uv.fs_realpath(dir)
  if not path then
    return false
  end
  local f = io.open(vim.fn.stdpath "state" .. "/trust", "r")
  if not f then
    return false
  end
  local answered = false
  for line in f:lines() do
    local _, file = line:match "^(%S+) (.+)$"
    if file == path then
      answered = true
      break
    end
  end
  f:close()
  return answered
end

-- terraform-ls's root: the nearest ancestor with .terraform, else the nearest with .git (all
-- ancestors are searched for .terraform first, as lspconfig's terraformls root_markers are), else
-- the file's directory. nil for an unnamed buffer, which has no file to start from.
local function terraform_root(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return nil
  end
  return vim.fs.root(bufnr, { ".terraform", ".git" }) or vim.fs.dirname(name)
end

-- Whether terraform-ls may start in root. A root the trust database does not answer gets a notice,
-- once per session, instead of a prompt.
local function terraform_root_allowed(root)
  if vim.fn.executable "terraform" == 0 then
    -- No CLI, so nothing runs provider plugins
    return true
  end
  if trust_answered(root) then
    -- Answered paths never prompt: allow returns true, deny nil
    return vim.secure.read(root) == true
  end
  if not notified_roots[root] then
    notified_roots[root] = true
    vim.notify(
      "terraform-ls is off in "
        .. root
        .. ": it would run provider plugins from .terraform directories in and below it. "
        .. "Run :TerraformTrust there to allow it.",
      vim.log.levels.INFO
    )
  end
  return false
end

-- Hands Neovim the root only when it is allowed, so terraform-ls never starts anywhere else
local function terraformls_root_dir(bufnr, on_dir)
  local root = terraform_root(bufnr)
  if root and terraform_root_allowed(root) then
    on_dir(root)
  end
end

return {
  "neovim/nvim-lspconfig",
  event = { "BufReadPre", "BufNewFile" },
  dependencies = {
    "mason-org/mason.nvim",
    "mason-org/mason-lspconfig.nvim",
  },
  config = function()
    -- Each config run (for example :Lazy reload) starts a new session: unanswered roots get the notice again
    notified_roots = {}

    -- Installed by Mason (native binaries, no npm)
    local mason_servers = {
      "gopls",
      "lua_ls",
      "sqls",
      "terraformls",
    }

    -- Installed by the system package manager (server = command it runs). These are Node programs;
    -- the Arch packages depend on nodejs, not npm. The commands are bare names found on PATH; setting
    -- them as lists means lspconfig's default lookup in root_dir/node_modules/.bin (jsonls, ts_ls,
    -- yamlls) is never used. A server is enabled only when its command is executable: a list cmd
    -- already skips a missing binary, but the gate keeps lsp.log free of errors and makes
    -- vim.lsp.is_enabled reflect what is installed.
    -- Keep in sync with install_language_servers in nvim-install.sh.
    local system_servers = {
      bashls = { "bash-language-server", "start" },
      dockerls = { "docker-langserver", "--stdio" },
      jsonls = { "vscode-json-language-server", "--stdio" },
      pyright = { "pyright-langserver", "--stdio" },
      ts_ls = { "typescript-language-server", "--stdio" },
      yamlls = { "yaml-language-server", "--stdio" },
    }

    -- lsp.lua alone decides whether a system server runs. mason-lspconfig would otherwise enable any
    -- Mason-installed copy by name with lspconfig's defaults, skipping the gates below; Mason puts its
    -- bin dir first on PATH, so a Mason-only copy still runs through the gated loop.
    -- docker_language_server is no longer used (see README), and a leftover Mason copy must never start.
    local not_auto_enabled = vim.tbl_keys(system_servers)
    table.insert(not_auto_enabled, "docker_language_server")
    table.sort(not_auto_enabled)

    local system_tsserver = system_tsserver_path()
    if not system_tsserver then
      -- Without a system TypeScript, ts_ls would load a repo's node_modules/typescript
      system_servers.ts_ls = nil
    end

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

    if system_servers.ts_ls then
      vim.lsp.config("ts_ls", { init_options = { tsserver = { path = system_tsserver } } })
    end

    -- Remote schemas are never downloaded: the schema stores are off, and registerContentRequest has the
    -- server send $schema URLs to Neovim, which has no handler for them. on_init repeats lspconfig's
    -- formatting line, because a function is replaced, not merged.
    vim.lsp.config("yamlls", {
      settings = {
        yaml = {
          schemaStore = { enable = false, url = "" },
          kubernetesCRDStore = { enable = false },
        },
      },
      on_init = function(client)
        client.server_capabilities.documentFormattingProvider = true
        client:notify "yaml/registerContentRequest"
      end,
    })

    -- http(s) $schema URLs go to Neovim, which has no handler, so jsonls never downloads them; local
    -- schemas still work
    vim.lsp.config("jsonls", { init_options = { handledSchemaProtocols = { "file" } } })

    vim.lsp.config("terraformls", { root_dir = terraformls_root_dir })

    -- Every vim.lsp.config call comes before mason_lspconfig.setup, because enabling re-fires FileType for open buffers
    local available = {}
    for server, cmd in pairs(system_servers) do
      if vim.fn.executable(cmd[1]) == 1 then
        vim.lsp.config(server, { cmd = cmd })
        table.insert(available, server)
      end
    end

    local mason_lspconfig = require "mason-lspconfig"

    mason_lspconfig.setup {
      ensure_installed = mason_servers,
      automatic_enable = { exclude = not_auto_enabled },
    }

    vim.lsp.enable(available)

    vim.api.nvim_create_user_command("TerraformTrust", function()
      local root = terraform_root(0)
      if not root then
        vim.notify("TerraformTrust: this buffer has no file", vim.log.levels.WARN)
        return
      end
      local ok, path = vim.secure.trust { action = "allow", path = root }
      if not ok then
        vim.notify("TerraformTrust: " .. path, vim.log.levels.ERROR)
        return
      end
      vim.notify("terraform-ls allowed in " .. path, vim.log.levels.INFO)
      vim.cmd.doautoall "nvim.lsp.enable FileType"
    end, { desc = "Allow terraform-ls, which runs provider plugins from .terraform, in this buffer's root" })

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
