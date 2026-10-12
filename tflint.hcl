# tflint config used by Neovim (lua/plugins/lint.lua). Repos' own .tflint.hcl files are ignored,
# because tflint executes the plugins they name. Add rules or plugins here; install plugin
# binaries into Neovim's data dir under tflint-plugins/.
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}
