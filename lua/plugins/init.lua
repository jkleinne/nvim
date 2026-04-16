require("lazy").setup({ { import = "plugins" } }, {
  install = {
    missing = true,
  },
  change_detection = {
    enabled = true,
    notify = true,
  },
})
