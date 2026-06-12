return {
  {
    "mfussenegger/nvim-lint",
    opts = function(_, opts)
      -- Enable golangci-lint for Go files
      opts.linters_by_ft = opts.linters_by_ft or {}
      opts.linters_by_ft.go = { "golangcilint" }
      return opts
    end,
  },

  -- Use system golangci-lint (from Nix) instead of Mason version
  {
    "mason-org/mason.nvim",
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}
      -- Remove golangci-lint from ensure_installed (use Nix version)
      opts.ensure_installed = vim.tbl_filter(function(tool)
        return tool ~= "golangci-lint"
      end, opts.ensure_installed)
      return opts
    end,
  },
}
