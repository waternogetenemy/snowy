-- snowy: 4 track generative sequencer
-- by robbiesleftboot
--
-- grid:
--   row 1       : generate buttons (cols 1-4: notes, vel, trigs, gates)
--   rows 3-6    : track steps (row 3 = track 1, etc.)
--   row 7       : mutes (cols 1-4)
--   row 8       : track select (cols 1-4)
--
-- encoders:
--   e1          : select param row
--   e2          : adjust left/first value of selected row
--   e3          : adjust right/second value (or division on density row)
--
-- keys:
--   k2          : panic (all notes off)
--   k3          : play / stop

engine.name = 'None'

local nb = include("snowy/lib/nb")
local musicutil = require('musicutil')
local lattice = require('lattice')

local g = grid.connect()

-- -------------------------------------------------------
-- constants
-- -------------------------------------------------------
local NUM_TRACKS = 4
local NUM_STEPS  = 16

local GEN_ROW        = 1
local TRACK_START_ROW = 3
local MUTE_ROW       = 7
local SELECT_ROW     = 8

local divisions      = {1/32, 1/16, 1/8, 1/4, 1/2, 1, 2, 4}
local division_names = {"1/32","1/16","1/8","1/4","1/2","1 beat","2 beats","4 beats"}

-- build scale list from musicutil, strip trailing octave
local SCALES = {}
for _, s in ipairs(musicutil.SCALES) do
  local ivs = {}
  for _, v in ipairs(s.intervals) do
    if v < 12 then ivs[#ivs+1] = v end
  end
  SCALES[#SCALES+1] = {name = s.name, intervals = ivs}
end

local NOTE_NAMES = {"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}

-- -------------------------------------------------------
-- state
-- -------------------------------------------------------
local selected_track = 1
local screen_cursor  = 1  -- 1=scale/root 2=vel 3=density 4=gate 5=division 6=swing
local is_playing     = true

local tracks = {}
for i = 1, NUM_TRACKS do
  tracks[i] = {
    steps      = {},
    notes      = {},
    velocities = {},
    gates      = {},
    playhead   = 0,
    muted      = false,
    loop_start = 1,
    loop_end   = NUM_STEPS,
  }
  for s = 1, NUM_STEPS do
    tracks[i].steps[s]      = false
    tracks[i].notes[s]      = 60
    tracks[i].velocities[s] = 80
    tracks[i].gates[s]      = 0.5
  end
end

-- hold state for loop point selection
local row_held     = {}  -- row_held[row] = col currently held, or nil
local row_loop_set = {}  -- true if the held press was used to set a loop range

-- -------------------------------------------------------
-- generation
-- -------------------------------------------------------
local function generate_notes(i)
  local t         = tracks[i]
  local scale_idx = params:get("t" .. i .. "_scale")
  local root      = params:get("t" .. i .. "_root") - 1  -- 0-11
  local intervals = SCALES[scale_idx].intervals
  local n         = #intervals
  local base      = 48 + root  -- start at octave 3
  for s = 1, NUM_STEPS do
    local degree = math.random(0, n * 3 - 1)
    local oct    = math.floor(degree / n)
    local idx    = (degree % n) + 1
    t.notes[s]   = math.max(0, math.min(127, base + oct * 12 + intervals[idx] - intervals[1]))
  end
end

local function generate_velocities(i)
  local t  = tracks[i]
  local lo = params:get("t" .. i .. "_vel_min")
  local hi = params:get("t" .. i .. "_vel_max")
  if lo > hi then lo, hi = hi, lo end
  for s = 1, NUM_STEPS do
    t.velocities[s] = math.random(lo, hi)
  end
end

local function generate_trigs(i)
  local t       = tracks[i]
  local density = params:get("t" .. i .. "_density") / 100
  for s = 1, NUM_STEPS do
    t.steps[s] = (math.random() < density)
  end
end

local function generate_gates(i)
  local t  = tracks[i]
  local lo = params:get("t" .. i .. "_gate_min")
  local hi = params:get("t" .. i .. "_gate_max")
  if lo > hi then lo, hi = hi, lo end
  for s = 1, NUM_STEPS do
    t.gates[s] = lo + math.random() * (hi - lo)
  end
end

-- -------------------------------------------------------
-- MIDI
-- -------------------------------------------------------
local midi_out = nil

local function setup_midi()
  midi_out = midi.connect(params:get("midi_out_device"))
end

-- -------------------------------------------------------
-- note on / off
-- -------------------------------------------------------
local function track_note_on(i, note, vel)
  local player = params:lookup_param("t" .. i .. "_voice"):get_player()
  if player then player:note_on(note, vel / 127) end
  if midi_out then
    midi_out:note_on(note, vel, params:get("t" .. i .. "_midi_ch"))
  end
end

local function track_note_off(i, note)
  local player = params:lookup_param("t" .. i .. "_voice"):get_player()
  if player then player:note_off(note) end
  if midi_out then
    midi_out:note_off(note, 0, params:get("t" .. i .. "_midi_ch"))
  end
end

local function all_notes_off()
  for i = 1, NUM_TRACKS do
    local player = params:lookup_param("t" .. i .. "_voice"):get_player()
    if player then player:note_off() end
  end
  if midi_out then
    for ch = 1, 16 do midi_out:cc(123, 0, ch) end
  end
end

local function restart_all()
  for i = 1, NUM_TRACKS do
    tracks[i].playhead = tracks[i].loop_start - 1
  end
end

-- -------------------------------------------------------
-- params
-- -------------------------------------------------------
local function setup_params()
  params:add_separator("SNOWY")

  for i = 1, NUM_TRACKS do
    params:add_separator("TRACK " .. i)

    local scale_names   = {}
    local default_scale = 1
    for j, s in ipairs(SCALES) do
      scale_names[#scale_names+1] = s.name
      if s.name == "Natural Minor" then default_scale = j end
    end
    params:add_option("t" .. i .. "_scale", "Scale", scale_names, default_scale)
    params:add_option("t" .. i .. "_root",  "Root",  NOTE_NAMES,  1)

    params:add_number("t" .. i .. "_vel_min", "Vel Min", 0, 127, 40)
    params:add_number("t" .. i .. "_vel_max", "Vel Max", 0, 127, 100)

    params:add_number("t" .. i .. "_density", "Density %", 0, 100, 50)

    params:add_control("t" .. i .. "_gate_min", "Gate Min",
      controlspec.new(0.0625, 4.0, "lin", 0.0625, 0.25, "b"))
    params:add_control("t" .. i .. "_gate_max", "Gate Max",
      controlspec.new(0.0625, 4.0, "lin", 0.0625, 1.0, "b"))

    params:add_option("t" .. i .. "_div", "Division", division_names, 2)

    params:add_number("t" .. i .. "_swing", "Swing %", 0, 50, 0)

    nb:add_param("t" .. i .. "_voice", "Track " .. i)

    params:add_number("t" .. i .. "_midi_ch", "MIDI Ch", 1, 16, i)
  end

  params:add_separator("MIDI")
  params:add_number("midi_out_device", "MIDI Out Device", 1, 4, 1)
  params:set_action("midi_out_device", function() setup_midi() end)

  nb:add_player_params()
  params:bang()
end

-- -------------------------------------------------------
-- lattice
-- -------------------------------------------------------
local seq_lattice = nil

local function setup_lattice()
  seq_lattice = lattice:new{ppqn = 96}

  for div_idx, div in ipairs(divisions) do
    local di = div_idx
    seq_lattice:new_sprocket({
      action = function()
        if not is_playing then return end
        for i = 1, NUM_TRACKS do
          if params:get("t" .. i .. "_div") == di then
            local t = tracks[i]
            local lo = t.loop_start
            local hi = t.loop_end
            if t.playhead < lo or t.playhead >= hi then
              t.playhead = lo
            else
              t.playhead = t.playhead + 1
            end
            local step = t.playhead
            if t.steps[step] and not t.muted then
              local note     = t.notes[step]
              local vel      = t.velocities[step]
              local gate     = t.gates[step]
              local ii       = i
              local bpm      = params:get("clock_tempo")
              local step_s   = divisions[di] * 4 * (60 / bpm)
              local swing_s  = (step % 2 == 0)
                and (params:get("t" .. i .. "_swing") / 100 * step_s)
                or 0
              clock.run(function()
                if swing_s > 0 then clock.sleep(swing_s) end
                track_note_on(ii, note, vel)
                clock.sleep(gate * 60 / bpm)
                track_note_off(ii, note)
              end)
            end
          end
        end
        grid_redraw()
      end,
      division = div
    })
  end

  clock.run(function()
    clock.sleep(0.1)
    seq_lattice:hard_restart()
  end)
end

-- -------------------------------------------------------
-- grid
-- -------------------------------------------------------
function grid_redraw()
  if not g then return end
  g:all(0)

  -- row 1: generate buttons (cols 1-4)
  for col = 1, 4 do
    g:led(col, GEN_ROW, 4)
  end

  -- rows 3-6: track steps
  for i = 1, NUM_TRACKS do
    local row = TRACK_START_ROW + (i - 1)
    local t   = tracks[i]
    for s = 1, NUM_STEPS do
      local is_head    = (s == t.playhead)
      local has_trig   = t.steps[s]
      local in_loop    = (s >= t.loop_start and s <= t.loop_end)
      local is_loop_edge = (s == t.loop_start or s == t.loop_end)
        and (t.loop_start ~= 1 or t.loop_end ~= NUM_STEPS)
      local br
      if is_head and has_trig then
        br = 15
      elseif is_head then
        br = 6
      elseif has_trig and in_loop then
        br = (i == selected_track) and 8 or 4
      elseif has_trig then
        br = 2
      elseif is_loop_edge then
        br = 3
      elseif in_loop then
        br = 0
      else
        br = 0
      end
      g:led(s, row, br)
    end
  end

  -- row 7: mutes (cols 1-4)
  for i = 1, NUM_TRACKS do
    g:led(i, MUTE_ROW, tracks[i].muted and 12 or 2)
  end

  -- row 8: track select (cols 1-4), play/stop (col 16)
  for i = 1, NUM_TRACKS do
    g:led(i, SELECT_ROW, (i == selected_track) and 15 or 4)
  end
  g:led(16, SELECT_ROW, is_playing and 15 or 4)

  g:refresh()
end

-- -------------------------------------------------------
-- screen
-- -------------------------------------------------------
local function scale_abbr(name)
  if #name <= 12 then return name end
  return string.gsub(string.sub(name, 1, 11), "%s+$", "") .. "."
end

function redraw()
  screen.clear()
  screen.aa(1)
  screen.font_face(1)

  local ti  = selected_track
  local lv  = function(q) return q == screen_cursor and 15 or 3 end

  -- shared header
  screen.font_size(7)
  screen.level(15)
  screen.move(2, 9)
  screen.text("Track " .. ti)
  screen.level(4)
  screen.move(128, 9)
  if not is_playing then
    screen.text_right("stopped")
  elseif tracks[ti].muted then
    screen.text_right("muted")
  end

  -- header divider
  screen.level(3)
  screen.line_width(0.5)
  screen.move(0, 12); screen.line(128, 12); screen.stroke()

  if screen_cursor <= 4 then
    -- PAGE 1: four quadrants
    screen.move(64, 12); screen.line(64,  64); screen.stroke()
    screen.move(0,  38); screen.line(128, 38); screen.stroke()

    local scale_name = scale_abbr(SCALES[params:get("t" .. ti .. "_scale")].name)
    local root_name  = NOTE_NAMES[params:get("t" .. ti .. "_root")]
    local vel_lo     = params:get("t" .. ti .. "_vel_min")
    local vel_hi     = params:get("t" .. ti .. "_vel_max")
    local density    = params:get("t" .. ti .. "_density")
    local gate_lo    = params:get("t" .. ti .. "_gate_min")
    local gate_hi    = params:get("t" .. ti .. "_gate_max")

    -- TL: notes
    screen.level(lv(1))
    screen.font_size(5)
    screen.move(2, 20); screen.text("notes")
    screen.font_size(7)
    screen.move(2, 29); screen.text(scale_name)
    screen.move(2, 36); screen.text(root_name)

    -- TR: velocity
    screen.level(lv(2))
    screen.font_size(5)
    screen.move(66, 20); screen.text("velocity")
    screen.font_size(7)
    screen.move(66, 29); screen.text(vel_lo .. " - " .. vel_hi)

    -- BL: trigs
    screen.level(lv(3))
    screen.font_size(5)
    screen.move(2, 46); screen.text("trigs")
    screen.font_size(7)
    screen.move(2, 57); screen.text(density .. "%")

    -- BR: gate
    screen.level(lv(4))
    screen.font_size(5)
    screen.move(66, 46); screen.text("gate (beats)")
    screen.font_size(7)
    screen.move(66, 57); screen.text(string.format("%.2f-%.2f", gate_lo, gate_hi))

  else
    -- PAGE 2: division + swing
    screen.move(64, 12); screen.line(64, 64); screen.stroke()

    local div_name = division_names[params:get("t" .. ti .. "_div")]
    local swing    = params:get("t" .. ti .. "_swing")

    -- left: division
    screen.level(lv(5))
    screen.font_size(5)
    screen.move(2, 26); screen.text("division")
    screen.font_size(9)
    screen.move(2, 42); screen.text(div_name)

    -- right: swing
    screen.level(lv(6))
    screen.font_size(5)
    screen.move(66, 26); screen.text("swing")
    screen.font_size(9)
    screen.move(66, 42); screen.text(swing .. "%")
  end

  screen.update()
end

-- -------------------------------------------------------
-- encoders
-- -------------------------------------------------------
function enc(n, d)
  local ti = selected_track
  if n == 1 then
    screen_cursor = ((screen_cursor - 1 + d) % 6) + 1
  elseif n == 2 then
    if     screen_cursor == 1 then params:delta("t" .. ti .. "_scale",    d)
    elseif screen_cursor == 2 then params:delta("t" .. ti .. "_vel_min",  d)
    elseif screen_cursor == 3 then params:delta("t" .. ti .. "_density",  d)
    elseif screen_cursor == 4 then params:delta("t" .. ti .. "_gate_min", d)
    elseif screen_cursor == 5 then params:delta("t" .. ti .. "_div",      d)
    elseif screen_cursor == 6 then params:delta("t" .. ti .. "_swing",    d)
    end
  elseif n == 3 then
    if     screen_cursor == 1 then params:delta("t" .. ti .. "_root",     d)
    elseif screen_cursor == 2 then params:delta("t" .. ti .. "_vel_max",  d)
    elseif screen_cursor == 3 then params:delta("t" .. ti .. "_density",  d)
    elseif screen_cursor == 4 then params:delta("t" .. ti .. "_gate_max", d)
    elseif screen_cursor == 5 then params:delta("t" .. ti .. "_div",      d)
    elseif screen_cursor == 6 then params:delta("t" .. ti .. "_swing",    d)
    end
  end
  redraw()
end

-- -------------------------------------------------------
-- keys
-- -------------------------------------------------------
function key(n, z)
  if z ~= 1 then return end
  if n == 2 then
    all_notes_off()
  elseif n == 3 then
    is_playing = not is_playing
    if not is_playing then all_notes_off() else restart_all() end
    redraw()
    grid_redraw()
  end
end

-- -------------------------------------------------------
-- grid input
-- -------------------------------------------------------
g.key = function(col, row, z)
  -- handle key-up for track rows (loop point release)
  if z == 0 then
    if row >= TRACK_START_ROW and row < TRACK_START_ROW + NUM_TRACKS then
      if row_held[row] == col then
        if not row_loop_set[row] then
          -- single tap: toggle trig
          local ti = row - TRACK_START_ROW + 1
          tracks[ti].steps[col] = not tracks[ti].steps[col]
          grid_redraw()
        end
        row_held[row]     = nil
        row_loop_set[row] = false
      end
    end
    return
  end

  if row == GEN_ROW then
    if     col == 1 then generate_notes(selected_track)
    elseif col == 2 then generate_velocities(selected_track)
    elseif col == 3 then generate_trigs(selected_track)
    elseif col == 4 then generate_gates(selected_track)
    end
    grid_redraw()

  elseif row >= TRACK_START_ROW and row < TRACK_START_ROW + NUM_TRACKS then
    local ti = row - TRACK_START_ROW + 1
    if col >= 1 and col <= NUM_STEPS then
      if row_held[row] ~= nil then
        -- second key while holding: set loop range
        local lo = math.min(row_held[row], col)
        local hi = math.max(row_held[row], col)
        tracks[ti].loop_start = lo
        tracks[ti].loop_end   = hi
        row_loop_set[row]     = true
        grid_redraw()
      else
        -- first press: hold and wait for key-up or second press
        row_held[row]     = col
        row_loop_set[row] = false
      end
    end

  elseif row == MUTE_ROW then
    if col >= 1 and col <= NUM_TRACKS then
      tracks[col].muted = not tracks[col].muted
      grid_redraw()
      redraw()
    end

  elseif row == SELECT_ROW then
    if col == 16 then
      is_playing = not is_playing
      if not is_playing then all_notes_off() else restart_all() end
      redraw()
      grid_redraw()
    elseif col >= 1 and col <= NUM_TRACKS then
      selected_track = col
      redraw()
      grid_redraw()
    end
  end
end

-- -------------------------------------------------------
-- init
-- -------------------------------------------------------
function init()
  nb:init()
  setup_params()
  setup_midi()
  setup_lattice()

  for i = 1, NUM_TRACKS do
    generate_notes(i)
    generate_velocities(i)
    generate_trigs(i)
    generate_gates(i)
  end

  grid_redraw()
  redraw()
end

function cleanup()
  all_notes_off()
end
