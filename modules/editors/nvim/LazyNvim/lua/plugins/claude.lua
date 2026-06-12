return {
  -- ClaudeCode.nvim - Claude Code CLI integration for Neovim
  {
    "coder/claudecode.nvim",
    lazy = false, -- Load immediately
    dependencies = {
      "folke/snacks.nvim",
    },
    opts = {
      -- Server settings
      auto_start = true,
      log_level = "info",

      -- API key helper that returns placeholder (proxy handles real auth)
      apiKeyHelper = "echo '-'",

      -- Environment variables for your Tailscale proxy
      env = {
        ANTHROPIC_BASE_URL = "https://ai.corp.ts.net/",
        API_TIMEOUT_MS = "3000000",
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1",
      },

      -- Selection tracking
      track_selection = true,
      focus_after_send = false,

      -- Terminal configuration
      terminal = {
        split_side = "right",
        split_width_percentage = 0.35,
        provider = "snacks", -- Use snacks for floating windows
        auto_close = true,

        -- Use git repository root as working directory
        cwd_provider = function(ctx)
          return require("claudecode.cwd").git_root(ctx.file_dir) or ctx.cwd
        end,

        -- Floating window configuration
        snacks_win_opts = {
          position = "float",
          width = 0.9,
          height = 0.9,
          border = "rounded",
          keys = {
            -- EscEsc to exit terminal insert mode (so you can scroll)
            exit_terminal = {
              "<Esc><Esc>",
              function()
                vim.cmd("stopinsert")
              end,
              mode = "t",
              desc = "Exit terminal insert mode",
            },
          },
        },
      },

      -- Diff integration
      diff_opts = {
        auto_close_on_accept = true,
        vertical_split = true,
        open_in_current_tab = true,
        keep_terminal_focus = false,
      },

      -- Available models
      models = {
        { name = "Claude Sonnet 4.5 (Latest)", value = "--model sonnet" },
        { name = "Claude Opus 4.5 (Latest)", value = "--model opus" },
        { name = "Claude Haiku 4.5 (Latest)", value = "--model haiku" },
        { name = "Opusplan (Opus + Sonnet)", value = "--model opusplan" },
      },
    },
    keys = {
      { "<leader>ac", "<cmd>ClaudeCode<cr>", desc = "Toggle Claude" },
      { "<C-i>", "<cmd>ClaudeCode<cr>", mode = { "n", "t" }, desc = "Toggle Claude" },
      { "<leader>af", "<cmd>ClaudeCodeFocus<cr>", desc = "Focus Claude" },
      { "<leader>ar", "<cmd>ClaudeCode --resume<cr>", desc = "Resume Claude" },
      { "<leader>aC", "<cmd>ClaudeCode --continue<cr>", desc = "Continue Claude" },
      { "<leader>am", "<cmd>ClaudeCodeSelectModel<cr>", desc = "Select Claude model" },
      { "<C-a>", "<cmd>ClaudeCodeAdd %<cr>", mode = "n", desc = "Add current buffer to Claude" },
      { "<leader>as", "<cmd>ClaudeCodeSend<cr>", mode = "v", desc = "Send selection to Claude" },
      { "<leader>aa", "<cmd>ClaudeCodeDiffAccept<cr>", desc = "Accept Claude changes" },
      { "<leader>ad", "<cmd>ClaudeCodeDiffDeny<cr>", desc = "Reject Claude changes" },
      { "<leader>ai", "<cmd>ClaudeCodeStatus<cr>", desc = "Claude status info" },
    },
  },

  -- Integration with which-key for better discoverability
  {
    "folke/which-key.nvim",
    optional = true,
    opts = {
      spec = {
        { "<leader>a", group = "ai/claude" },
      },
    },
  },
}
