return {
  "goolord/alpha-nvim",
  config = function()
    local alpha = require "alpha"
    local dashboard = require "alpha.themes.dashboard"
    dashboard.section.header.val = {
      [[                                                                       ]],
      [[  ██████   █████                   █████   █████  ███                  ]],
      [[ ░░██████ ░░███                   ░░███   ░░███  ░░░                   ]],
      [[  ░███░███ ░███   ██████   ██████  ░███    ░███  ████  █████████████   ]],
      [[  ░███░░███░███  ███░░███ ███░░███ ░███    ░███ ░░███ ░░███░░███░░███  ]],
      [[  ░███ ░░██████ ░███████ ░███ ░███ ░░███   ███   ░███  ░███ ░███ ░███  ]],
      [[  ░███  ░░█████ ░███░░░  ░███ ░███  ░░░█████░    ░███  ░███ ░███ ░███  ]],
      [[  █████  ░░█████░░██████ ░░██████     ░░███      █████ █████░███ █████ ]],
      [[ ░░░░░    ░░░░░  ░░░░░░   ░░░░░░       ░░░      ░░░░░ ░░░░░ ░░░ ░░░░░  ]],
      [[                                                                       ]],
      [[                     λ it be like that sometimes λ                     ]],
    }

    dashboard.section.buttons.val = {
      dashboard.button("f", " Find file", ":Telescope find_files hidden=true no_ignore=true<CR>"),
      dashboard.button("e", "  New file", ":ene <BAR> startinsert <CR>"),
      dashboard.button("c", "  Configuration", ":e ~/.config/nvim/init.lua <CR>"),
      dashboard.button("u", "  Update plugins", ":Lazy sync<CR>"),
      dashboard.button("r", "  Recently opened files", "<cmd>Telescope oldfiles<CR>"),
      dashboard.button("l", "  Open last session", "<cmd>AutoSession restore<CR>"),
      dashboard.button("q", "󰈆  Quit", ":qa<CR>"),
    }

    local handle, err = io.popen "fortune -s"
    if err or handle == nil then
      vim.notify("alpha: fortune unavailable (" .. (err or "no handle") .. ")", vim.log.levels.DEBUG)
      dashboard.section.footer.val = "May the truth be found."
      alpha.setup(dashboard.opts)
      return
    end
    local fortune = handle:read "*a"
    handle:close()
    dashboard.section.footer.val = fortune
    alpha.setup(dashboard.opts)
  end,
}
