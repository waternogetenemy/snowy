-- snowy: 4 track generative sequencer
-- by robbiesleftboot
--
-- grid:
--   row 1       : gen buttons (cols 1-4: notes, vel, trigs, gates)
--                 col 6: octave up  col 8: scale/root  col 9: division  col 10: swing  col 11: nudge
--                 cols 13-16: volume up (tr 1-4, brightness = level)
--   row 2       : instant generate (cols 1-4: notes, vel, trigs, gates)
--                 col 6: octave down  cols 13-16: volume down (tr 1-4)
--   rows 3-6    : track steps (row 3 = track 1, etc.)
--   row 7       : mutes (cols 1-4)
--   row 8       : track select (cols 1-4)  col 16: play/stop
--
-- encoders:
--   e1          : select track
--   e2 / e3     : adjust params for current view
--
-- keys:
--   k2          : panic (all notes off)
--   k3          : generate (in gen views) / play-stop (in div/swing/default)

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
local QUICK_ROW      = 2
local TRACK_START_ROW = 3
local MUTE_ROW       = 7
local SELECT_ROW     = 8

local divisions      = {1/32, 1/16, 1/8, 1/4, 1/2, 1, 2, 4}
local division_names = {"1/32","1/16","1/8","1/4","1/2","1 beat","2 beats","4 beats"}

local gate_lengths      = {1/16, 1/8, 1/4, 1/2, 1, 2}
local gate_length_names = {"1/16","1/8","1/4","1/2","1","2"}

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
local is_playing     = true
local gen_mode       = 0  -- 0=overview, 1=notes, 2=vel, 3=trigs, 4=gates, 5=div, 6=swing, 7=octave, 8=nudge, 9=scale, 10=vol

local gen_dirty = {}  -- gen_dirty[track][1-4]: param changed since last K3

local tracks = {}
for i = 1, NUM_TRACKS do
  gen_dirty[i] = {false, false, false, false}
  tracks[i] = {
    steps      = {},
    notes      = {},
    degrees    = {},
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
    tracks[i].degrees[s]    = 0
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
local function remap_notes(i)
  local t         = tracks[i]
  local scale_idx = params:get("t" .. i .. "_scale")
  local root      = params:get("t" .. i .. "_root") - 1
  local intervals = SCALES[scale_idx].intervals
  local n         = #intervals
  local base      = 48 + root
  local oct_lo    = params:get("t" .. i .. "_oct_lo")
  for s = 1, NUM_STEPS do
    local deg  = t.degrees[s]
    local oct  = math.floor(deg / n) + oct_lo
    local idx  = (deg % n) + 1
    t.notes[s] = math.max(0, math.min(127, base + oct * 12 + intervals[idx] - intervals[1]))
  end
end

local function generate_notes(i)
  local t         = tracks[i]
  local scale_idx = params:get("t" .. i .. "_scale")
  local intervals = SCALES[scale_idx].intervals
  local n         = #intervals
  local oct_lo    = params:get("t" .. i .. "_oct_lo")
  local oct_hi    = params:get("t" .. i .. "_oct_hi")
  if oct_lo > oct_hi then oct_lo, oct_hi = oct_hi, oct_lo end
  local total = n * (oct_hi - oct_lo + 1)
  for s = 1, NUM_STEPS do
    t.degrees[s] = math.random(0, total - 1)
  end
  remap_notes(i)
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
  local t     = tracks[i]
  local count = params:get("t" .. i .. "_density")
  local idx   = {}
  for s = 1, NUM_STEPS do idx[s] = s end
  for s = NUM_STEPS, 2, -1 do
    local j = math.random(s)
    idx[s], idx[j] = idx[j], idx[s]
  end
  for s = 1, NUM_STEPS do t.steps[s] = false end
  for s = 1, count do t.steps[idx[s]] = true end
end

local function generate_gates(i)
  local t    = tracks[i]
  local lo_i = params:get("t" .. i .. "_gate_min")
  local hi_i = params:get("t" .. i .. "_gate_max")
  if lo_i > hi_i then lo_i, hi_i = hi_i, lo_i end
  for s = 1, NUM_STEPS do
    t.gates[s] = gate_lengths[math.random(lo_i, hi_i)]
  end
end

local function nudge_rotate(ti, d)
  local t   = tracks[ti]
  local n   = NUM_STEPS
  local rot = d % n
  if rot == 0 then return end
  local ns, nn, nv, ng = {}, {}, {}, {}
  for s = 1, n do
    local src = ((s - 1 - rot) % n) + 1
    ns[s] = t.steps[src]
    nn[s] = t.notes[src]
    nv[s] = t.velocities[src]
    ng[s] = t.gates[src]
  end
  t.steps = ns; t.notes = nn; t.velocities = nv; t.gates = ng
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
    params:add_group("track_" .. i, "Track " .. i, 16)

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

    params:add_number("t" .. i .. "_density", "Density", 1, 16, 8)

    params:add_option("t" .. i .. "_gate_min", "Gate Min", gate_length_names, 2)
    params:add_option("t" .. i .. "_gate_max", "Gate Max", gate_length_names, 4)

    params:add_option("t" .. i .. "_div", "Division", division_names, 2)

    params:add_number("t" .. i .. "_oct_lo", "Oct Lo", -3, 3, -1)
    params:add_number("t" .. i .. "_oct_hi", "Oct Hi", -3, 3,  1)

    params:add_number("t" .. i .. "_swing",  "Swing",  0, 100, 50)
    params:add_number("t" .. i .. "_octave", "Octave", -3, 3,  0)
    params:add_number("t" .. i .. "_vol",    "Volume", 0,  16, 16)

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
            local vol = params:get("t" .. i .. "_vol")
            if t.steps[step] and not t.muted and vol > 0 then
              local note     = math.max(0, math.min(127, t.notes[step] + params:get("t" .. i .. "_octave") * 12))
              local vel      = math.floor(t.velocities[step] * vol / 16)
              local gate     = t.gates[step]
              local ii       = i
              local bpm      = params:get("clock_tempo")
              local step_s   = divisions[di] * 4 * (60 / bpm)
              local swing    = params:get("t" .. i .. "_swing")
              local offset   = (swing - 50) / 50 * step_s
              local delay_s
              if offset >= 0 then
                delay_s = (step % 2 == 0) and offset or 0
              else
                delay_s = (step % 2 == 1) and (-offset) or 0
              end
              clock.run(function()
                if delay_s > 0 then clock.sleep(delay_s) end
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

  -- row 1: gen param screens (cols 1-4), division/swing/octave (cols 6-8)
  for col = 1, 4 do
    g:led(col, GEN_ROW, (col == gen_mode) and 15 or 4)
  end
  local cur_oct = params:get("t" .. selected_track .. "_octave")
  g:led(6,  GEN_ROW,  cur_oct < 3  and ((gen_mode == 7) and 15 or 5) or 2)
  g:led(8,  GEN_ROW, (gen_mode == 9) and 15 or 4)
  g:led(9,  GEN_ROW, (gen_mode == 5) and 15 or 4)
  g:led(10, GEN_ROW, (gen_mode == 6) and 15 or 4)
  g:led(11, GEN_ROW, (gen_mode == 8) and 15 or 4)

  -- row 2: instant generate (cols 1-4), octave down (col 6)
  for col = 1, 4 do
    g:led(col, QUICK_ROW, 3)
  end
  g:led(6, QUICK_ROW, cur_oct > -3 and 5 or 2)

  -- cols 13-16: volume per track (A=up, B=down)
  for i = 1, NUM_TRACKS do
    local vol = params:get("t" .. i .. "_vol")
    local on_vol_screen = (gen_mode == 10)
    local a_br = vol == 0 and 1 or (on_vol_screen and (i == selected_track) and 15 or 5)
    local b_br = vol == 0 and 0 or 2
    g:led(12 + i, GEN_ROW,   a_br)
    g:led(12 + i, QUICK_ROW, b_br)
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
  screen.aa(0)
  screen.font_face(1)
  screen.font_size(8)

  local ti = selected_track

  local function rule(y)
    screen.level(2)
    screen.line_width(1)
    screen.move(0, y); screen.line(128, y); screen.stroke()
  end

  local function header(label)
    screen.level(5)
    screen.move(2, 9); screen.text(label)
    screen.move(126, 9); screen.text_right("tr." .. ti)
    rule(12)
  end

  local function hints(left, right)
    screen.level(3)
    if left  then screen.move(2, 61);   screen.text(left) end
    if right then screen.move(126, 61); screen.text_right(right) end
  end

  if gen_mode == 0 then
    screen.level(15)
    screen.move(2, 9); screen.text("Track " .. ti)
    screen.level(4)
    screen.move(126, 9)
    if not is_playing then screen.text_right("stopped")
    elseif tracks[ti].muted then screen.text_right("muted") end
    rule(12)

    screen.level(2)
    screen.line_width(1)
    screen.move(64, 12); screen.line(64, 64); screen.stroke()

    local div_name = division_names[params:get("t" .. ti .. "_div")]
    local swing    = params:get("t" .. ti .. "_swing")

    screen.level(4);  screen.move(2,  24); screen.text("division")
    screen.level(15); screen.move(2,  38); screen.text(div_name)
    screen.level(4);  screen.move(66, 24); screen.text("swing")
    screen.level(15); screen.move(66, 38); screen.text(swing .. "%")

  elseif gen_mode == 1 then
    header("notes")
    local lo = params:get("t"..ti.."_oct_lo")
    local hi = params:get("t"..ti.."_oct_hi")
    local lo_s = (lo > 0 and "+" or "") .. lo
    local hi_s = (hi > 0 and "+" or "") .. hi
    screen.level(15)
    screen.move(2, 34); screen.text(lo_s .. " to " .. hi_s .. " oct")
    hints("e2 lo  e3 hi", "k3 gen")

  elseif gen_mode == 2 then
    header("velocity")
    local lo = params:get("t"..ti.."_vel_min")
    local hi = params:get("t"..ti.."_vel_max")
    screen.level(15)
    screen.move(2, 34); screen.text(lo .. " - " .. hi)
    hints("e2 min  e3 max", "k3 gen")

  elseif gen_mode == 3 then
    header("trigs")
    local count = params:get("t"..ti.."_density")
    screen.level(15)
    screen.move(2, 34); screen.text(count .. " of 16")
    hints("e3 count", "k3 gen")

  elseif gen_mode == 4 then
    header("gate")
    local lo_i = params:get("t"..ti.."_gate_min")
    local hi_i = params:get("t"..ti.."_gate_max")
    screen.level(15)
    screen.move(2, 34)
    screen.text(gate_length_names[lo_i] .. " - " .. gate_length_names[hi_i])
    hints("e2 min  e3 max", "k3 gen")

  elseif gen_mode == 5 then
    header("division")
    screen.level(15)
    screen.move(2, 38); screen.text(division_names[params:get("t"..ti.."_div")])
    hints("e3")

  elseif gen_mode == 6 then
    header("swing")
    screen.level(15)
    screen.move(2, 38); screen.text(params:get("t"..ti.."_swing") .. "%")
    hints("e3  (50=straight)")

  elseif gen_mode == 7 then
    header("octave")
    local oct = params:get("t"..ti.."_octave")
    screen.level(15)
    screen.move(2, 38); screen.text((oct > 0 and "+" or "") .. oct)
    hints("A6 up  B6 down  e3")

  elseif gen_mode == 8 then
    header("nudge")
    screen.level(15)
    screen.move(2, 38); screen.text("rotate pattern")
    hints("e3 forward / back")

  elseif gen_mode == 9 then
    header("scale")
    local scale_name = scale_abbr(SCALES[params:get("t"..ti.."_scale")].name)
    local root_name  = NOTE_NAMES[params:get("t"..ti.."_root")]
    screen.level(15)
    screen.move(2, 28); screen.text(scale_name)
    screen.move(2, 40); screen.text(root_name)
    hints("e2 scale  e3 root")

  elseif gen_mode == 10 then
    header("volume")
    local col_w = 30
    for i = 1, NUM_TRACKS do
      local vol = params:get("t" .. i .. "_vol")
      local x   = 2 + (i - 1) * col_w
      screen.level(i == ti and 5 or 2)
      screen.move(x, 22); screen.text("tr." .. i)
      screen.level(i == ti and 15 or 6)
      local label = (vol == 0) and "off" or tostring(vol)
      screen.move(x, 38); screen.text(label)
    end
    hints("A up  B down  e3")
  end

  screen.update()
end

-- -------------------------------------------------------
-- encoders
-- -------------------------------------------------------
function enc(n, d)
  local ti = selected_track
  if n == 1 then
    selected_track = ((selected_track - 1 + d) % NUM_TRACKS) + 1
    redraw(); grid_redraw()
    return
  end
  if gen_mode == 0 then
    if     n == 2 then params:delta("t" .. ti .. "_div",   d)
    elseif n == 3 then params:delta("t" .. ti .. "_swing", d) end
  elseif gen_mode == 1 then
    if     n == 2 then params:delta("t" .. ti .. "_oct_lo", d)
    elseif n == 3 then params:delta("t" .. ti .. "_oct_hi", d) end
    gen_dirty[ti][1] = true
  elseif gen_mode == 2 then
    if     n == 2 then params:delta("t" .. ti .. "_vel_min", d)
    elseif n == 3 then params:delta("t" .. ti .. "_vel_max", d) end
    gen_dirty[ti][2] = true
  elseif gen_mode == 3 then
    if n == 3 then
      params:delta("t" .. ti .. "_density", d)
      gen_dirty[ti][3] = true
    end
  elseif gen_mode == 4 then
    if     n == 2 then params:delta("t" .. ti .. "_gate_min", d)
    elseif n == 3 then params:delta("t" .. ti .. "_gate_max", d) end
    gen_dirty[ti][4] = true
  elseif gen_mode == 5 then
    if n == 3 then params:delta("t" .. ti .. "_div", d) end
  elseif gen_mode == 6 then
    if n == 3 then params:delta("t" .. ti .. "_swing", d) end
  elseif gen_mode == 7 then
    if n == 3 then params:delta("t" .. ti .. "_octave", d) end
  elseif gen_mode == 8 then
    if n == 3 then nudge_rotate(ti, d); grid_redraw() end
  elseif gen_mode == 9 then
    if     n == 2 then params:delta("t" .. ti .. "_scale", d)
    elseif n == 3 then params:delta("t" .. ti .. "_root",  d) end
    remap_notes(ti)
  elseif gen_mode == 10 then
    if n == 3 then params:delta("t" .. ti .. "_vol", d) end
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
    if gen_mode >= 1 and gen_mode <= 4 then
      local ti = selected_track
      gen_dirty[ti][gen_mode] = true  -- always include current screen
      if gen_dirty[ti][1] then generate_notes(ti) end
      if gen_dirty[ti][2] then generate_velocities(ti) end
      if gen_dirty[ti][3] then generate_trigs(ti) end
      if gen_dirty[ti][4] then generate_gates(ti) end
      for j = 1, 4 do gen_dirty[ti][j] = false end
    else
      is_playing = not is_playing
      if not is_playing then all_notes_off() else restart_all() end
    end
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
    local changed = true
    if col >= 1 and col <= 4 then
      gen_mode = (gen_mode == col) and 0 or col
    elseif col == 6 then
      params:delta("t" .. selected_track .. "_octave", 1)
      gen_mode = 7
    elseif col == 8 then
      gen_mode = (gen_mode == 9) and 0 or 9
    elseif col == 9 then
      gen_mode = (gen_mode == 5) and 0 or 5
    elseif col == 10 then
      gen_mode = (gen_mode == 6) and 0 or 6
    elseif col == 11 then
      gen_mode = (gen_mode == 8) and 0 or 8
    elseif col >= 13 and col <= 16 then
      selected_track = col - 12
      params:delta("t" .. selected_track .. "_vol", 1)
      gen_mode = 10
    else
      changed = false
    end
    if changed then redraw(); grid_redraw() end

  elseif row == QUICK_ROW then
    if col >= 1 and col <= 4 then
      local ti = selected_track
      if col == 1 then generate_notes(ti)
      elseif col == 2 then generate_velocities(ti)
      elseif col == 3 then generate_trigs(ti)
      elseif col == 4 then generate_gates(ti)
      end
      gen_dirty[ti][col] = false
    elseif col == 6 then
      params:delta("t" .. selected_track .. "_octave", -1)
      gen_mode = 7
      redraw(); grid_redraw()
    elseif col >= 13 and col <= 16 then
      selected_track = col - 12
      params:delta("t" .. selected_track .. "_vol", -1)
      gen_mode = 10
      redraw(); grid_redraw()
    end

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
