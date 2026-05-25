local vim = vim

---------------------------------------------------------------------------
-- Packpath: load nightfly + treesitter parsers
---------------------------------------------------------------------------
local pack = vim.env.NVIM_FZF_PACK_PATH
vim.opt.runtimepath:prepend(pack)
for _, dir in ipairs(vim.fn.globpath(pack .. "/pack/*/start", "*", false, true)) do
  vim.opt.runtimepath:prepend(dir)
end

---------------------------------------------------------------------------
-- UI + colorscheme
---------------------------------------------------------------------------
vim.opt.laststatus = 0
vim.opt.cmdheight = 0
vim.opt.signcolumn = "no"
vim.opt.number = false
vim.opt.relativenumber = false
vim.opt.ruler = false
vim.opt.showcmd = false
vim.opt.showmode = false
vim.opt.termguicolors = true
vim.opt.splitright = true
vim.opt.fillchars = "vert: "

vim.g.nightflyTerminalColors = false
vim.g.nightflyItalics = false

vim.api.nvim_create_augroup("builtin", { clear = true })
vim.api.nvim_create_autocmd("colorscheme", {
  group = "builtin",
  pattern = "*",
  callback = function()
    local function resolve(name)
      local hl = vim.api.nvim_get_hl(0, { name = name })
      if hl.link then return vim.api.nvim_get_hl(0, { name = hl.link }) end
      return hl
    end

    vim.api.nvim_set_hl(0, "function", vim.tbl_extend("force", resolve("function"), { italic = true }))
    vim.api.nvim_set_hl(0, "keyword", vim.tbl_extend("force", resolve("keyword"), { italic = true, bold = true }))
    vim.api.nvim_set_hl(0, "string", vim.tbl_extend("force", resolve("string"), { italic = true }))
    vim.api.nvim_set_hl(0, "normalfloat", { bg = "#1e2633" })
    vim.api.nvim_set_hl(0, "floatborder", { bg = "none", fg = "#1e2633" })
    vim.api.nvim_set_hl(0, "normal", { bg = "none" })
    vim.api.nvim_set_hl(0, "signcolumn", { bg = "none" })
    vim.api.nvim_set_hl(0, "StatusLine", { bg = "none", fg = "none" })
    vim.api.nvim_set_hl(0, "StatusLineNc", { bg = "none", fg = "none" })
    vim.api.nvim_set_hl(0, "MsgArea", { bg = "none", fg = "#cccccc" })
    vim.api.nvim_set_hl(0, "WinSeparator", { bg = "none", fg = "none" })
  end,
})

vim.cmd.colorscheme("nightfly")

---------------------------------------------------------------------------
-- Preview
---------------------------------------------------------------------------
local focus_file = vim.fn.tempname()
local selection_file = vim.fn.tempname()
local preview_buf = vim.api.nvim_create_buf(false, true)
local last_path = ""
local timer = vim.uv.new_timer()

local function update_preview()
  local ok, lines = pcall(vim.fn.readfile, focus_file)
  if not ok or #lines == 0 then return end
  local path = lines[1]
  if path == last_path or path == "" then return end
  last_path = path

  if vim.fn.filereadable(path) == 0 then
    vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, {})
    return
  end

  pcall(vim.treesitter.stop, preview_buf)
  local content = vim.fn.readfile(path, "", 1000)
  vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, content)

  local ft = vim.filetype.match({ buf = preview_buf, filename = path })
  if ft then
    vim.bo[preview_buf].filetype = ft
    local lang = vim.treesitter.language.get_lang(ft) or ft
    pcall(vim.treesitter.start, preview_buf, lang)
  else
    vim.bo[preview_buf].filetype = ""
  end
end

---------------------------------------------------------------------------
-- fzf command
---------------------------------------------------------------------------
local extra_args = vim.env.NVIM_FZF_ARGS or ""
local header = [['exact  !not  [!]^prefix  [!]suffix$]]

local fzf_cmd = table.concat({
  "fd --type f --hidden --strip-cwd-prefix --no-ignore-vcs --color never |",
  "fzf",
  string.format("--bind 'focus:execute-silent(printf %%s {} > %s)'", focus_file),
  "--multi --keep-right",
  "--header-first --header", vim.fn.shellescape(header),
  extra_args,
  ">", selection_file,
}, " ")

---------------------------------------------------------------------------
-- Layout + terminal
---------------------------------------------------------------------------
vim.api.nvim_create_autocmd("VimEnter", {
  callback = function()
    local term_buf = vim.api.nvim_create_buf(false, true)
    local term_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(term_win, term_buf)

    vim.fn.termopen(fzf_cmd, {
      on_exit = function(_, code)
        vim.schedule(function()
          timer:stop()
          timer:close()
          vim.fn.delete(focus_file)
          if code == 0 then
            local sel = vim.fn.readfile(selection_file)
            vim.fn.delete(selection_file)
            if #sel > 0 then
              vim.cmd("only")
              vim.cmd("edit " .. vim.fn.fnameescape(sel[1]))
              for i = 2, #sel do
                vim.cmd("badd " .. vim.fn.fnameescape(sel[i]))
              end
              return
            end
          end
          vim.fn.delete(selection_file)
          vim.cmd("qa!")
        end)
      end,
    })

    -- Preview split on right
    vim.cmd("vsplit")
    local preview_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(preview_win, preview_buf)
    vim.wo[preview_win].number = false
    vim.wo[preview_win].relativenumber = false
    vim.wo[preview_win].signcolumn = "no"

    -- Terminal: 45% width
    vim.api.nvim_win_set_width(term_win, math.floor(vim.o.columns * 0.45))

    -- Focus terminal, start insert
    vim.api.nvim_set_current_win(term_win)
    vim.cmd("startinsert")

    -- Poll for preview updates
    timer:start(50, 50, vim.schedule_wrap(update_preview))
  end,
})
