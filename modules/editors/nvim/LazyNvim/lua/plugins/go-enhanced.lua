return {
  -- Treesitter for Go
  {
    "nvim-treesitter/nvim-treesitter",
    opts = { ensure_installed = { "go", "gomod", "gosum", "gowork" } },
  },

  -- Mason tools for Go
  {
    "mason-org/mason.nvim",
    opts = { ensure_installed = { "goimports", "gopls", "delve" } },
  },

  -- gopls LSP configuration
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        gopls = {
          settings = {
            gopls = {
              -- Fix go.mod replace directive errors
              allowModfileModifications = true,
              -- Let goimports handle formatting/imports, not gopls
              gofumpt = false,
              -- Enable inlay hints
              hints = {
                assignVariableTypes = true,
                compositeLiteralFields = true,
                compositeLiteralTypes = true,
                constantValues = true,
                functionTypeParameters = true,
                parameterNames = true,
                rangeVariableTypes = true,
              },
              -- Enable advanced analyses
              analyses = {
                fieldalignment = true,
                nilness = true,
                unusedparams = true,
                unusedwrite = true,
                useany = true,
              },
              -- Enable codelenses
              codelenses = {
                gc_details = false,
                generate = true,
                regenerate_cgo = true,
                run_govulncheck = true,
                test = true,
                tidy = true,
                upgrade_dependency = true,
                vendor = true,
              },
              -- Static check
              staticcheck = true,
              -- Complete unimported packages
              completeUnimported = true,
              -- Use placeholders for function parameters
              usePlaceholders = true,
              -- Semantic tokens
              semanticTokens = true,
            },
          },
        },
      },
    },
  },

  -- Neotest for Go with inline test running
  {
    "nvim-neotest/neotest",
    optional = true,
    dependencies = {
      "nvim-neotest/neotest-go",
    },
    opts = {
      adapters = {
        ["neotest-go"] = {
          -- Options for neotest-go
          experimental = {
            test_table = true,
          },
          args = { "-count=1", "-timeout=60s" },
        },
      },
    },
    keys = {
      {
        "<leader>tr",
        function()
          require("neotest").run.run()
        end,
        desc = "Run nearest test",
      },
      {
        "<leader>tf",
        function()
          require("neotest").run.run(vim.fn.expand("%"))
        end,
        desc = "Run file tests",
      },
      {
        "<leader>td",
        function()
          require("neotest").run.run({ strategy = "dap" })
        end,
        desc = "Debug nearest test",
      },
      {
        "<leader>ts",
        function()
          require("neotest").summary.toggle()
        end,
        desc = "Toggle test summary",
      },
      {
        "<leader>to",
        function()
          require("neotest").output.open({ enter = true, auto_close = true })
        end,
        desc = "Show test output",
      },
      {
        "<leader>tO",
        function()
          require("neotest").output_panel.toggle()
        end,
        desc = "Toggle test output panel",
      },
      {
        "<leader>tS",
        function()
          require("neotest").run.stop()
        end,
        desc = "Stop test",
      },
    },
  },
}
