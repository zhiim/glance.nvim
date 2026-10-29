vim.api.nvim_create_user_command('Glance', function(event)
  if event.args == 'resume' or event.args == 'back' then
    require('glance').actions[event.args]()
  else
    require('glance').open(event.args)
  end
end, {
  nargs = 1,
  complete = function(arg)
    local list = vim.tbl_keys(require('glance.lsp').methods)
    table.insert(list, 'resume')
    table.insert(list, 'back')

    return vim.tbl_filter(function(s)
      return string.match(s, '^' .. arg)
    end, list)
  end,
})
