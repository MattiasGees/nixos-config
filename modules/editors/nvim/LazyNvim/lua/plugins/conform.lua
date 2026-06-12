return {
  {
    "stevearc/conform.nvim",
    opts = function(_, opts)
      -- Use goimports for Go formatting (handles imports + formatting)
      -- This matches Tailscale repo tooling
      opts.formatters_by_ft = opts.formatters_by_ft or {}
      opts.formatters_by_ft.go = { "goimports" }
      return opts
    end,
  },
}
