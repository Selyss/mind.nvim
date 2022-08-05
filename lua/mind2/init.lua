local renderer = require'neo-tree.ui.renderer'
local manager = require'neo-tree.sources.manager'
local events = require'neo-tree.events'

local M = {}

local path = require'plenary.path'

function notify(msg, lvl)
  vim.notify(msg, lvl, { title = 'Mind', icon = '' })
end

-- FIXME: recursively ensure that the paths are created
-- FIXME: group settings by categories, like opts.ui.*, opts.fs.*, opts.edit.*, etc. etc.
local defaults = {
  -- state & data stuff
  state_path = '~/.local/share/mind.nvim/mind.json',
  data_dir = '~/.local/share/mind.nvim/data',

  -- edition stuff
  data_extension = '.md',
  data_header = '# %s',

  -- UI stuff
  width = 30,
  root_marker = ' ',
  data_marker = ' ',

  -- highlight stuff
  hl_mark_closed = 'LineNr',
  hl_mark_open = 'LineNr',
  hl_node_root = 'Function',
  hl_node_leaf = 'String',
  hl_node_parent = 'Title',
  hl_modifier_local = 'Comment',
  hl_modifier_grey = 'Grey',

  -- keybindings stuff
  use_default_keys = true,
}

M.NodeType = {
  ROOT = 0,
  PARENT = 1,
  LEAF = 2,
  LOCAL = 3,
}

function compute_hl(type)
  if (type == M.NodeType.ROOT) then
    return M.opts.hl_node_root
  elseif (type == M.NodeType.PARENT) then
    return M.opts.hl_node_parent
  elseif (type == M.NodeType.LEAF) then
    return M.opts.hl_node_leaf
  elseif (type == M.NodeType.LOCAL) then
    return M.opts.hl_modifier_local
  end
end

function expand_opts_paths()
  M.opts.state_path = vim.fn.expand(M.opts.state_path)
  M.opts.data_dir = vim.fn.expand(M.opts.data_dir)
end

M.setup = function(opts)
  M.opts = setmetatable(opts or {}, {__index = defaults})

  expand_opts_paths()

  M.load_state()
end

-- Load the state.
--
-- If CWD has a .mind/, the projects part of the state is overriden with its contents. However, the main tree remains in
-- M.opts.state_path.
M.load_state = function()
  M.state = {
    -- Main tree, used for when no specific project is wanted.
    tree = {
      contents = {
        { text = 'Main', type = M.NodeType.ROOT },
      },
      icon = M.opts.root_marker,
    },

    -- Per-project trees; this is a map from the CWD of projects to the actual tree for that project.
    projects = {},
  }

  -- Local tree, for local projects.
  M.local_tree = nil

  if (M.opts == nil or M.opts.state_path == nil) then
    notify('cannot load shit', 4)
    return
  end

  local file = io.open(M.opts.state_path, 'r')

  if (file == nil) then
    notify('no global state', 4)
  else
    local encoded = file:read()
    file:close()

    if (encoded ~= nil) then
      M.state = vim.json.decode(encoded)
    end
  end

  -- if there is a local state, we get it and replace the M.state.projects[the_project] with it
  local cwd = vim.fn.getcwd()
  local local_mind = path:new(cwd, '.mind')
  if (local_mind:is_dir()) then
    -- we have a local mind; read the projects state from there
    file = io.open(path:new(cwd, '.mind', 'state.json'):expand(), 'r')

    if (file == nil) then
      notify('no local state', 4)
      M.local_tree = {
        contents = {
          { text = cwd:match('^.+/(.+)$'), type = M.NodeType.ROOT },
          { text = ' local', type = M.NodeType.LOCAL },
        },
        icon = M.opts.root_marker,
      }
    else
      encoded = file:read()
      file:close()

      if (encoded ~= nil) then
        M.local_tree = vim.json.decode(encoded)
      end
    end
  end
end

M.save_state = function()
  if (M.opts == nil or M.opts.state_path == nil) then
    return
  end

  local file = io.open(M.opts.state_path, 'w')

  if (file == nil) then
    notify(string.format('cannot save state at %s', M.opts.state_path), 4)
  else
    local encoded = vim.json.encode(M.state)
    file:write(encoded)
    file:close()
  end

  -- if there is a local state, we write the local project
  local cwd = vim.fn.getcwd()
  local local_mind = path:new(cwd, '.mind')
  if (local_mind:is_dir()) then
    -- we have a local mind
    file = io.open(path:new(cwd, '.mind', 'state.json'):expand(), 'w')

    if (file == nil) then
      notify(string.format('cannot save local project at %s', cwd), 4)
    else
      local encoded = vim.json.encode(M.local_tree)
      file:write(encoded)
      file:close()
    end
  end
end

-- Create a new random file in a given directory.
--
-- Return the path to the created file.
function new_data_file(dir, name, content)
  local filename = vim.fn.strftime('%Y%m%d%H%M%S-') .. name
  local file_path = path:new(dir, filename):expand()

  local file = io.open(file_path, 'w')

  if (file == nil) then
    notify('cannot open data file: ' .. file_path)
    return nil
  end

  file:write(content)
  file:close()

  return file_path
end

function open_data(tree, i, dir)
  local node = M.get_node_by_nb(tree, i)

  if (node == nil) then
    notify('open_data nope', 4)
    return
  end

  local data = node.data
  if (data == nil) then
    contents = string.format(M.opts.data_header, node.contents[1].text)
    data = new_data_file(dir, node.contents[1].text .. M.opts.data_extension, contents)

    if (data == nil) then
      return
    end

    node.data = data
  end

  M.rerender(tree)

  local winnr = require('window-picker').pick_window()

  if (winnr ~= nil) then
    vim.api.nvim_set_current_win(winnr)
    vim.api.nvim_cmd({ cmd = 'e', args = { data } }, {})
  end
end

M.open_data_cursor = function(tree, data_dir)
  if (data_dir == nil) then
    notify('data directory not available', 4)
    return
  end

  local line = vim.api.nvim_win_get_cursor(0)[1] - 1
  open_data(tree, line, data_dir)
end

M.Node = function(name, children)
  local contents = {
    { text = name, type = M.NodeType.LEAF }
  }
  return {
    contents = contents,
    is_expanded = false,
    children = children
  }
end

-- Wrap a function call expecting a tree by extracting from the state the right tree, depending on CWD.
--
-- The `save` argument will automatically save the state after the function is done, if set to `true`.
M.wrap_tree_fn = function(f, save)
  local cwd = vim.fn.getcwd()
  local project_tree = M.state.projects[cwd]

  if (project_tree == nil) then
    M.wrap_main_tree_fn(f, save)
  else
    M.wrap_project_tree_fn(f, save, project_tree)
  end
end

-- Wrap a function call expecting a tree with the main tree.
M.wrap_main_tree_fn = function(f, save)
  f(M.state.tree)

  if (save) then
    M.save_state()
  end
end

-- Wrap a function call expecting a project tree.
--
-- If the projec tree doesn’t exist, it is automatically created.
M.wrap_project_tree_fn = function(f, save, tree, use_global)
  if (tree == nil) then
    if (M.local_tree == nil or use_global) then
      local cwd = vim.fn.getcwd()
      tree = M.state.projects[cwd]

      if (tree == nil) then
        tree = {
          contents = {
            { text = cwd:match('^.+/(.+)$'), type = M.NodeType.ROOT },
          },
          icon = M.opts.root_marker,
        }
        M.state.projects[cwd] = tree
      end
    else
      tree = M.local_tree
    end
  end

  f(tree)

  if (save) then
    M.save_state()
  end
end

function get_ith(parent, node, i)
  if (i == 0) then
    return parent, node, nil
  end

  i = i - 1

  if (node.children ~= nil and node.is_expanded) then
    for _, child in ipairs(node.children) do
      p, n, i = get_ith(node, child, i)

      if (n ~= nil) then
        return p, n, nil
      end
    end
  end

  return nil, nil, i
end

M.get_node_by_nb = function(tree, i)
  local _, node, _ = get_ith(nil, tree, i)
  return node
end

M.get_node_and_parent_by_nb = function(tree, i)
  local parent, node, _ = get_ith(nil, tree, i)
  return parent, node
end

-- Add a node as children of another node.
function add_node(tree, i, name)
  local grand_parent, parent = M.get_node_and_parent_by_nb(tree, i)

  if (parent == nil) then
    notify('add_node nope', 4)
    return
  end

  local node = M.Node(name, nil)

  if (parent.children == nil) then
    parent.children = {}

    if (grand_parent ~= nil) then
      parent.contents[1].type = M.NodeType.PARENT
    end
  end

  parent.children[#parent.children + 1] = node
  parent.is_expanded = true

  M.rerender(tree)
end

-- Ask the user for input and add as a node at the current location.
M.input_node_cursor = function(tree)
  local line = vim.api.nvim_win_get_cursor(0)[1] - 1
  vim.ui.input({ prompt = 'Node name: ' }, function(input)
    if (input ~= nil) then
      add_node(tree, line, input)
    end
  end)
end

-- Delete a node at a given location.
function delete_node(tree, i)
  local parent, node = M.get_node_and_parent_by_nb(tree, i)

  if (node == nil) then
    notify('add_node nope', 4)
    return
  end

  if (parent == nil) then
    return false
  end

  local children = {}
  for _, child in ipairs(parent.children) do
    if (child ~= node) then
      children[#children + 1] = child
    end
  end

  if (#children == 0) then
    children = nil
  end

  parent.children = children

  M.rerender(tree)
end

-- Delete the node under the cursor.
M.delete_node_cursor = function(tree)
  local line = vim.api.nvim_win_get_cursor(0)[1] - 1
  delete_node(tree, line)
end

-- Rename a node at a given location.
function rename_node(tree, i)
  local node = M.get_node_by_nb(tree, i)

  if (node == nil) then
    notify('rename_node nope', 4)
    return
  end

  vim.ui.input({ prompt = string.format('Rename node: %s -> ', node.contents[1].text) }, function(input)
    if (input ~= nil) then
      node.contents[1].text = input
    end
  end)

  M.rerender(tree)
end

-- Rename the node under the cursor.
M.rename_node_cursor = function(tree)
  local line = vim.api.nvim_win_get_cursor(0)[1] - 1
  rename_node(tree, line)
end

-- Change a node’s icon at a given location.
function change_icon_node(tree, i)
  local node = M.get_node_by_nb(tree, i)

  if (node == nil) then
    notify('change_icon_node nope', 4)
    return
  end

  local prompt = 'Node icon: '
  if (node.icon ~= nil) then
    prompt = prompt .. node.icon .. ' -> '
  end


  vim.ui.input({ prompt = prompt }, function(input)
    if (input ~= nil) then
      node.icon = input
    end
  end)

  M.rerender(tree)
end

-- Change the icon of the node under the cursor.
M.change_icon_node_cursor = function(tree)
  local line = vim.api.nvim_win_get_cursor(0)[1] - 1
  change_icon_node(tree, line)
end

function compute_node_name_and_hl(node)
  local name = ''
  local partial_hls = {}

  -- the icon goes first
  if (node.icon ~= nil) then
    name = node.icon
    partial_hls[#partial_hls + 1] = {
      group = compute_hl(node.contents[1].type),
      width = #name,
    }
  end

  -- then the contents
  for _, content in ipairs(node.contents) do
    name = name .. content.text

    partial_hls[#partial_hls + 1] = {
      group = compute_hl(content.type),
      width = #content.text
    }
  end

  if (node.data ~= nil) then
    local marker = ' ' .. M.opts.data_marker
    name = name .. marker

    partial_hls[#partial_hls +1 ] = {
      group = M.opts.hl_modifier_grey,
      width = #marker,
    }
  end

  return name, partial_hls
end

function render_node(node, depth, lines, hls)
  local line = string.rep(' ', depth * 2)
  local name, partial_hls = compute_node_name_and_hl(node)
  local hl_col_start = #line
  local hl_line = #lines

  if (node.children ~= nil) then
    if (node.is_expanded) then
      local mark = ' '
      local hl_col_end = hl_col_start + #mark
      hls[#hls + 1] = { group = M.opts.hl_mark_open, line = hl_line, col_start = hl_col_start, col_end = hl_col_end }
      lines[#lines + 1] = line .. mark .. name

      for _, hl in ipairs(partial_hls) do
        hl_col_start = hl_col_end
        hl_col_end = hl_col_start + hl.width
        hls[#hls + 1] = { group = hl.group, line = hl_line, col_start = hl_col_start, col_end = hl_col_end }
      end

      depth = depth + 1
      for _, child in ipairs(node.children) do
        render_node(child, depth, lines, hls)
      end
    else
      local mark = ' '
      local hl_col_end = hl_col_start + #mark
      hls[#hls + 1] = { group = M.opts.hl_mark_closed, line = hl_line, col_start = hl_col_start, col_end = hl_col_end }
      lines[#lines + 1] = line .. mark .. name

      for _, hl in ipairs(partial_hls) do
        hl_col_start = hl_col_end
        hl_col_end = hl_col_start + hl.width
        hls[#hls + 1] = { group = hl.group, line = hl_line, col_start = hl_col_start, col_end = hl_col_end }
      end
    end
  else
    local hl_col_end = hl_col_start
    lines[#lines + 1] = line .. name

    for _, hl in ipairs(partial_hls) do
      hl_col_start = hl_col_end
      hl_col_end = hl_col_start + hl.width
      hls[#hls + 1] = { group = hl.group, line = hl_line, col_start = hl_col_start, col_end = hl_col_end }
    end
  end
end

function render_tree(tree)
  local lines = {}
  local hls = {}
  render_node(tree, 0, lines, hls)
  return lines, hls
end

M.render = function(tree, bufnr)
  local lines, hls = render_tree(tree)

  vim.api.nvim_buf_set_option(bufnr, 'modifiable', true)

  -- set the lines
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, lines)

  -- apply the highlights
  for _, hl in ipairs(hls) do
    vim.api.nvim_buf_add_highlight(bufnr, 0, hl.group, hl.line, hl.col_start, hl.col_end)
  end

  vim.api.nvim_buf_set_option(bufnr, 'modifiable', false)
end

-- Re-render a tree if it was already rendered buffer.
M.rerender = function(tree)
  M.render(tree, 0)
end

M.open_tree = function(tree, data_dir, default_keys)
  -- window
  vim.api.nvim_cmd({ cmd = 'vsplit'}, {})
  vim.api.nvim_win_set_width(0, M.opts.width)

  -- buffer
  local bufnr = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(bufnr, 'mind')
  vim.api.nvim_win_set_buf(0, bufnr)
  vim.api.nvim_buf_set_option(bufnr, 'filetype', 'mind')
  vim.api.nvim_win_set_option(0, 'nu', false)

  -- tree
  M.render(tree, bufnr)

  -- keymaps for debugging
  if (default_keys) then
    vim.keymap.set('n', '<tab>', function()
      M.toggle_node_cursor(tree)
      M.save_state()
    end, { buffer = true, noremap = true, silent = true })

    vim.keymap.set('n', 'q', M.close, { buffer = true, noremap = true, silent = true })

    vim.keymap.set('n', 'a', function()
      M.input_node_cursor(tree)
      M.save_state()
    end, { buffer = true, noremap = true, silent = true })

    vim.keymap.set('n', 'd', function()
      M.delete_node_cursor(tree)
      M.save_state()
    end, { buffer = true, noremap = true, silent = true })

    vim.keymap.set('n', 'r', function()
      M.rename_node_cursor(tree)
      M.save_state()
    end, { buffer = true, noremap = true, silent = true })

    vim.keymap.set('n', '<cr>', function()
      M.open_data_cursor(tree, data_dir)
      M.save_state()
    end, { buffer = true, noremap = true, silent = true })

    vim.keymap.set('n', 'I', function()
      M.change_icon_node_cursor(tree)
      M.save_state()
    end, { buffer = true, noremap = true, silent = true })
  end
end

function get_project_data_dir()
  local cwd = vim.fn.getcwd()
  local local_mind = path:new(cwd, '.mind/data')
  if (local_mind:is_dir()) then
    return path:new(cwd, '.mind/data'):expand()
  else
    return nil
  end

  return M.opts.data_dir
end

M.open_main = function()
  M.wrap_main_tree_fn(function(tree) M.open_tree(tree, M.opts.data_dir, M.opts.use_default_keys) end)
end

M.open_project = function(use_global)
  M.wrap_project_tree_fn(function(tree) M.open_tree(tree, get_project_data_dir(), M.opts.use_default_keys) end, false, nil, use_global)
end

M.close = function()
  -- vim.api.nvim_win_hide(0)
  vim.api.nvim_buf_delete(0, { force = true })
end

M.toggle_node = function(tree, i)
  local node = M.get_node_by_nb(tree, i)

  if (node ~= nil) then
    node.is_expanded = not node.is_expanded
  end

  M.rerender(tree)
end

M.toggle_node_cursor = function(tree)
  local line = vim.api.nvim_win_get_cursor(0)[1] - 1
  M.toggle_node(tree, line)
end

return M