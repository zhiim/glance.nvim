-- Run from the repository root: nvim --headless -u NONE -l tests/history.lua
-- Neovim 0.9: nvim --headless -u NONE -c 'lua dofile("tests/history.lua")'
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.columns = 140
vim.o.lines = 45
vim.o.swapfile = false
vim.cmd('runtime plugin/glance.lua')

local function eq(expected, actual, message)
  assert(
    vim.deep_equal(expected, actual),
    (message or '')
      .. '\nexpected: '
      .. vim.inspect(expected)
      .. '\nactual: '
      .. vim.inspect(actual)
  )
end

local function run()
  local Glance = require('glance')
  local lsp = require('glance.lsp')
  local folds = require('glance.folds')
  local config = require('glance.config')
  Glance.setup({ theme = { enable = false }, preserve_win_context = false })
  local current
  local original_create = Glance.create
  Glance.create = function(self, opts)
    current = original_create(self, opts)
    return current
  end

  -- Only the LSP transport is replaced; use real buffers, floats and mappings.
  local pending = {}
  local requests = 0
  lsp.request = function(method, _, cb)
    requests = requests + 1
    table.insert(pending, { method = method, cb = cb })
  end
  vim.lsp.get_client_by_id = function()
    return { offset_encoding = 'utf-16' }
  end

  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  local files = {}
  for _, name in ipairs({ 'a', 'b', 'c' }) do
    local path = dir .. '/' .. name .. '.lua'
    local lines = {}
    for i = 1, 120 do
      lines[i] = ('local function_%s_%d = other()'):format(name, i)
    end
    vim.fn.writefile(lines, path)
    files[name] = path
  end
  vim.cmd('edit ' .. vim.fn.fnameescape(files.a))
  local parent = vim.api.nvim_get_current_win()

  local function location(name, row)
    return {
      uri = vim.uri_from_fname(files[name]),
      range = {
        start = { line = row, character = 6 },
        ['end'] = { line = row, character = 14 },
      },
    }
  end
  local a = { location('a', 10), location('a', 25), location('b', 20) }
  local b = { location('b', 30) }
  local c = { location('c', 40) }

  local function reply(results, index)
    local request = table.remove(pending, index or 1)
    request.cb(results, {
      client_id = 1,
      params = {
        textDocument = { uri = vim.uri_from_fname(files.a) },
        position = { line = 10, character = 6 },
      },
    })
    if Glance.is_open() then
      vim.api.nvim_exec_autocmds('CursorMoved', { buffer = current.list.bufnr })
    end
    vim.wait(10, function()
      return false
    end)
  end
  local function query(results, method)
    Glance.open(method or 'definitions')
    reply(results)
  end
  local function back()
    -- Exercise the actual default buffer-local b mapping.
    vim.cmd('normal b')
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = current.list.bufnr })
  end
  local function preview_view(line, top)
    vim.api.nvim_set_current_win(current.preview.winnr)
    vim.api.nvim_win_call(current.preview.winnr, function()
      vim.fn.winrestview({ lnum = line, col = 9, topline = top })
    end)
  end
  local function check_state(state)
    local restored = current:snapshot()
    eq(state, restored, 'restored query, folds, views and focus')
  end

  Glance.actions.back() -- Safe before the first session.
  query(a, 'references')
  eq(Glance.actions.back, vim.fn.maparg('b', 'n', false, true).callback)
  current.list:next({ skip_groups = true })
  current:update_preview(current.list:get_current_item())
  preview_view(29, 23)
  eq(Glance.actions.back, vim.fn.maparg('b', 'n', false, true).callback)
  local state_a = current:snapshot()
  query(b)
  preview_view(38, 31)
  local state_b = current:snapshot()
  query(c, 'implementations')
  local before_back = requests
  back()
  check_state(state_b)
  back()
  check_state(state_a)
  eq(before_back, requests, 'back must not send another LSP request')
  back()
  check_state(state_a) -- At the root, b is a no-op.

  -- Restoring a folded starting group must not depend on its hidden location.
  current.list:close_fold(current.list:get_current_item())
  preview_view(34, 28)
  local folded_a = current:snapshot()
  query(b)
  vim.api.nvim_set_current_win(current.list.winnr)
  back() -- b also works from the result list.
  check_state(folded_a)

  query({})
  check_state(folded_a)
  eq(0, #current.history, 'empty results must not add history')

  -- A late response cannot overwrite the view restored by b.
  query(b)
  Glance.open('definitions')
  back()
  check_state(folded_a)
  reply(c)
  check_state(folded_a)

  -- The most recently issued query wins even if replies arrive out of order.
  Glance.open('definitions')
  Glance.open('implementations')
  reply(c, 2)
  reply(b, 1)
  eq(c, current.session.results)
  eq(1, #current.history)
  back()
  check_state(folded_a)

  -- Same-location queries still restore highlights after clearing the namespace.
  current.list:open_fold(current.list:get_current_item())
  current.list:next({ skip_groups = true })
  current:update_preview(current.list:get_current_item())
  local same = { location('a', current.preview.current_location.start_line) }
  query(same)
  query(same)
  back()
  assert(
    #vim.api.nvim_buf_get_extmarks(
        current.preview.current_location.bufnr,
        config.namespace,
        0,
        -1,
        {}
      ) > 0,
    'restored preview must be highlighted'
  )

  query(c)
  Glance.actions.close()
  eq(false, Glance.is_open())
  eq(parent, vim.api.nvim_get_current_win())
  Glance.actions.back()
  Glance.actions.resume()
  eq(c, current.session.results, 'resume uses the last displayed query')
  eq(0, #current.history, 'closed sessions must not leak history')
  Glance.actions.close()

  query(a)
  Glance.open('definitions')
  Glance.actions.close()
  reply(b)
  eq(false, Glance.is_open(), 'late replies must not reopen a closed session')
  query(c)
  eq(0, #current.history)
  Glance.actions.close()
  vim.fn.delete(dir, 'rf')
  print('Glance history integration tests passed')
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
  io.stderr:write(err .. '\n')
  vim.cmd('cquit 1')
else
  vim.cmd('qa!')
end
