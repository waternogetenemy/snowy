-- snowy: 4 track generative sequencer
-- by robbiesleftboot

engine.name = 'None'

local g = grid.connect()

function init()
  params:add_separator("SNOWY")
  params:bang()
end

function redraw()
  screen.clear()
  screen.move(64, 32)
  screen.level(15)
  screen.text_center("snowy")
  screen.update()
end

function key(n, z)
end

function enc(n, d)
end

function grid.key(x, y, z)
end
