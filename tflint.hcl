# tflint config used by Neovim (lua/plugins/lint.lua). Repos' own .tflint.hcl files are ignored,
# because tflint executes the plugins they name. Add rules or plugins here; plugins named here run
# inside tflint. A third-party ruleset needs `source` and `version` and must be installed into
# Neovim's plugin dir (tflint-plugins/ under Neovim's data dir), or tflint reports nothing at all
# (not even the bundled rules) and the editor stays silent. Both paths below assume the default
# NVIM_APPNAME (nvim):
#   TFLINT_PLUGIN_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/tflint-plugins" \
#     tflint --init --config "${XDG_CONFIG_HOME:-$HOME/.config}/nvim/tflint.hcl"
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}
