return {
  {
    "lewis6991/gitsigns.nvim",
    opts = {
      signs = {
        add = { text = "│" },
        change = { text = "│" },
        delete = { text = "_" },
        topdelete = { text = "‾" },
        changedelete = { text = "~" },
        untracked = { text = "┆" },
      },
      signcolumn = true,
      numhl = false,
      linehl = false,
      word_diff = false,
      watch_gitdir = {
        follow_files = true,
      },
      attach_to_untracked = true,

      -- Enable inline git blame (like VSCode)
      current_line_blame = true,
      current_line_blame_opts = {
        virt_text = true,
        virt_text_pos = "eol", -- 'eol' | 'overlay' | 'right_align'
        delay = 500, -- delay in ms before showing blame
        ignore_whitespace = false,
      },
      current_line_blame_formatter = "<author>, <author_time:%Y-%m-%d> - <summary>",

      -- Additional keybindings for git operations
      on_attach = function(bufnr)
        local gs = package.loaded.gitsigns
        local map = vim.keymap.set

        -- Navigation
        map("n", "]c", function()
          if vim.wo.diff then
            return "]c"
          end
          vim.schedule(function()
            gs.next_hunk()
          end)
          return "<Ignore>"
        end, { expr = true, buffer = bufnr, desc = "Next git hunk" })

        map("n", "[c", function()
          if vim.wo.diff then
            return "[c"
          end
          vim.schedule(function()
            gs.prev_hunk()
          end)
          return "<Ignore>"
        end, { expr = true, buffer = bufnr, desc = "Previous git hunk" })

        -- Actions
        map("n", "<leader>gs", gs.stage_hunk, { buffer = bufnr, desc = "Stage hunk" })
        map("n", "<leader>gr", gs.reset_hunk, { buffer = bufnr, desc = "Reset hunk" })
        map("v", "<leader>gs", function()
          gs.stage_hunk({ vim.fn.line("."), vim.fn.line("v") })
        end, { buffer = bufnr, desc = "Stage hunk" })
        map("v", "<leader>gr", function()
          gs.reset_hunk({ vim.fn.line("."), vim.fn.line("v") })
        end, { buffer = bufnr, desc = "Reset hunk" })
        map("n", "<leader>gS", gs.stage_buffer, { buffer = bufnr, desc = "Stage buffer" })
        map("n", "<leader>gu", gs.undo_stage_hunk, { buffer = bufnr, desc = "Undo stage hunk" })
        map("n", "<leader>gR", gs.reset_buffer, { buffer = bufnr, desc = "Reset buffer" })
        map("n", "<leader>gp", gs.preview_hunk, { buffer = bufnr, desc = "Preview hunk" })
        map("n", "<leader>gb", function()
          gs.blame_line({ full = true })
        end, { buffer = bufnr, desc = "Show full git blame" })
        map("n", "<leader>gB", gs.toggle_current_line_blame, { buffer = bufnr, desc = "Toggle inline blame" })
        map("n", "<leader>gd", gs.diffthis, { buffer = bufnr, desc = "Diff this" })
        map("n", "<leader>gD", function()
          gs.diffthis("~")
        end, { buffer = bufnr, desc = "Diff this ~" })

        -- Text object
        map({ "o", "x" }, "ih", ":<C-U>Gitsigns select_hunk<CR>", { buffer = bufnr, desc = "Select git hunk" })
      end,
    },
  },

  -- Integration with which-key for better discoverability
  {
    "folke/which-key.nvim",
    optional = true,
    opts = {
      spec = {
        { "<leader>g", group = "git" },
      },
    },
  },
}
