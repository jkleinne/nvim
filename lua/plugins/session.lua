return {
  "rmagatti/auto-session",
  lazy = false,
  opts = {
    auto_restore = false,
    auto_save = true,
    suppressed_dirs = { "~/", "~/Downloads", "/tmp" },
    pre_save_cmds = { "Neotree close" },
  },
}
