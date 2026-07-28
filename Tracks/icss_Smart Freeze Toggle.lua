-- @description Smart Freeze Toggle
-- @author icanseesounds
-- @version 1.0.1
-- @changelog
--   Simplify the ReaPack description
-- @about
--   Toggles the freeze state of every selected track.
--
--   * Unfrozen track: measure a safe post-FX tail, then freeze to stereo.
--   * Frozen track: unfreezes one freeze layer.
--   * Mixed multi-track selections are processed independently.
--
--   Requires the free SWS/S&M extension.

local SCRIPT_NAME = "Smart Freeze Toggle"
local CMD_FREEZE_TO_STEREO = 41223
local CMD_UNFREEZE_TRACKS = 41644
local CMD_RENDER_SELECTED_AREA_TO_STEREO_STEM = 41716

local AUDIO_PROBE_SECONDS = 0.010
local MIDI_PROBE_SECONDS = 0.050
local MAX_FREEZE_TAIL_SECONDS = 5.0
local SAFETY_SECONDS = 1.0
local SILENCE_HOLD_SECONDS = 0.250
local SILENCE_THRESHOLD_DB = -80.0
local ANALYSIS_SAMPLE_RATE = 44100
local ANALYSIS_CHANNELS = 2
local ANALYSIS_BLOCK_FRAMES = 4096
local RENDER_TAIL_CONFIG_KEY = "rendertail"

local SILENCE_THRESHOLD = 10 ^ (SILENCE_THRESHOLD_DB / 20)

local function show_message(message)
  reaper.ShowMessageBox(message, SCRIPT_NAME, 0)
end

local function track_name(track)
  local _, name = reaper.GetTrackName(track)
  if name == "" then
    local number = math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER"))
    return "Track " .. tostring(number)
  end
  return name
end

local function collect_selected_tracks()
  local tracks = {}
  for index = 0, reaper.CountSelectedTracks(0) - 1 do
    tracks[#tracks + 1] = reaper.GetSelectedTrack(0, index)
  end
  return tracks
end

local function restore_track_selection(tracks)
  reaper.Main_OnCommand(40297, 0) -- Track: Unselect all tracks
  for _, track in ipairs(tracks) do
    if reaper.ValidatePtr2(0, track, "MediaTrack*") then
      reaper.SetTrackSelected(track, true)
    end
  end
end

local function get_track_item_end(track)
  local item_count = reaper.CountTrackMediaItems(track)
  if item_count == 0 then
    return nil
  end

  local material_end = 0
  for index = 0, item_count - 1 do
    local item = reaper.GetTrackMediaItem(track, index)
    local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    material_end = math.max(material_end, item_start + item_length)
  end
  return material_end
end

local function get_material_end(track, visited)
  visited = visited or {}
  if visited[track] then
    return nil
  end
  visited[track] = true

  local material_end = get_track_item_end(track)

  -- Receives include ordinary buses and sidechain inputs. Following them makes
  -- the probe happen when the material feeding the selected track actually
  -- ends, rather than only considering items placed directly on that track.
  for receive_index = 0, reaper.GetTrackNumSends(track, -1) - 1 do
    local source_track = reaper.GetTrackSendInfo_Value(
      track,
      -1,
      receive_index,
      "P_SRCTRACK"
    )
    if source_track
        and reaper.ValidatePtr2(0, source_track, "MediaTrack*") then
      local source_end = get_material_end(source_track, visited)
      if source_end then
        material_end = math.max(material_end or source_end, source_end)
      end
    end
  end

  -- Parent routing is not always exposed as an ordinary receive, so include
  -- folder descendants explicitly as well.
  local folder_depth = reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH")
  if folder_depth > 0 then
    local track_number = math.floor(
      reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")
    )
    local depth = folder_depth
    local index = track_number
    while index < reaper.CountTracks(0) and depth > 0 do
      local child = reaper.GetTrack(0, index)
      local child_end = get_material_end(child, visited)
      if child_end then
        material_end = math.max(material_end or child_end, child_end)
      end
      depth = depth
        + reaper.GetMediaTrackInfo_Value(child, "I_FOLDERDEPTH")
      index = index + 1
    end
  end

  return material_end
end

local function write_noise_wav(path)
  local sample_rate = ANALYSIS_SAMPLE_RATE
  local frame_count = math.max(1, math.floor(AUDIO_PROBE_SECONDS * sample_rate + 0.5))
  local bytes_per_sample = 2
  local channels = 1
  local data_size = frame_count * channels * bytes_per_sample

  local file, open_error = io.open(path, "wb")
  if not file then
    error("Could not create the temporary noise file: " .. tostring(open_error))
  end

  local header = table.concat({
    "RIFF",
    string.pack("<I4", 36 + data_size),
    "WAVE",
    "fmt ",
    string.pack("<I4I2I2I4I4I2I2",
      16,
      1,
      channels,
      sample_rate,
      sample_rate * channels * bytes_per_sample,
      channels * bytes_per_sample,
      bytes_per_sample * 8
    ),
    "data",
    string.pack("<I4", data_size)
  })
  file:write(header)

  -- A deterministic generator makes the probe repeatable. A short fade at
  -- both edges prevents the probe itself from adding unnecessary clicks.
  local random_state = 0x13579B
  local fade_frames = math.max(1, math.floor(sample_rate * 0.001))
  local samples = {}
  for frame = 0, frame_count - 1 do
    random_state = (1103515245 * random_state + 12345) % 0x80000000
    local noise = (random_state / 0x40000000) - 1.0
    local fade_in = math.min(1.0, frame / fade_frames)
    local fade_out = math.min(1.0, (frame_count - 1 - frame) / fade_frames)
    local sample = noise * 0.5 * math.min(fade_in, fade_out)
    samples[#samples + 1] = string.pack("<i2", math.floor(sample * 32767))
  end
  file:write(table.concat(samples))
  file:close()
end

local function add_audio_probe(track, position, temporary)
  local path = os.tmpname() .. "_icss_smart_freeze_probe.wav"
  temporary.file_path = path
  write_noise_wav(path)

  local source = reaper.PCM_Source_CreateFromFile(path)
  if not source then
    error("REAPER could not open the temporary noise file.")
  end

  local item = reaper.AddMediaItemToTrack(track)
  if not item then
    error("Could not create the temporary audio probe item.")
  end
  temporary.probe_item = item

  local take = reaper.AddTakeToMediaItem(item)
  if not take then
    error("Could not create a take for the temporary audio probe.")
  end

  reaper.SetMediaItemTake_Source(take, source)
  reaper.SetMediaItemInfo_Value(item, "D_POSITION", position)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", AUDIO_PROBE_SECONDS)
  reaper.SetMediaItemInfo_Value(item, "B_MUTE", 0)
  reaper.SetMediaItemInfo_Value(item, "B_LOOPSRC", 0)
  return position + AUDIO_PROBE_SECONDS
end

local function find_recent_midi_note(track)
  local best_end = -math.huge
  local best_channel, best_pitch, best_velocity = 0, 60, 100

  for item_index = 0, reaper.CountTrackMediaItems(track) - 1 do
    local item = reaper.GetTrackMediaItem(track, item_index)
    for take_index = 0, reaper.CountTakes(item) - 1 do
      local take = reaper.GetTake(item, take_index)
      if take and reaper.TakeIsMIDI(take) then
        local _, note_count = reaper.MIDI_CountEvts(take)
        for note_index = 0, note_count - 1 do
          local ok, _, muted, _, end_ppq, channel, pitch, velocity =
            reaper.MIDI_GetNote(take, note_index)
          if ok and not muted then
            local note_end = reaper.MIDI_GetProjTimeFromPPQPos(take, end_ppq)
            if note_end > best_end then
              best_end = note_end
              best_channel = channel
              best_pitch = pitch
              best_velocity = velocity
            end
          end
        end
      end
    end
  end

  return best_channel, best_pitch, best_velocity
end

local function add_midi_probe(track, position, temporary)
  local item_end = position + MIDI_PROBE_SECONDS
  local item = reaper.CreateNewMIDIItemInProj(track, position, item_end, false)
  if not item then
    error("Could not create the temporary MIDI probe item.")
  end
  temporary.probe_item = item

  local take = reaper.GetActiveTake(item)
  if not take then
    error("Could not create a take for the temporary MIDI probe.")
  end

  local channel, pitch, velocity = find_recent_midi_note(track)
  local start_ppq = reaper.MIDI_GetPPQPosFromProjTime(take, position)
  local end_ppq = reaper.MIDI_GetPPQPosFromProjTime(take, item_end)
  local inserted = reaper.MIDI_InsertNote(
    take,
    false,
    false,
    start_ppq,
    end_ppq,
    channel,
    pitch,
    velocity,
    false
  )
  if not inserted then
    error("Could not insert the temporary MIDI probe note.")
  end
  reaper.MIDI_Sort(take)
  return item_end
end

local function render_probe_window(track, probe_start, probe_end, temporary)
  local scan_end = probe_end + MAX_FREEZE_TAIL_SECONDS
  temporary.time_start, temporary.time_end =
    reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  temporary.source_mute =
    reaper.GetMediaTrackInfo_Value(track, "B_MUTE")

  local existing_tracks = {}
  for index = 0, reaper.CountTracks(0) - 1 do
    existing_tracks[reaper.GetTrack(0, index)] = true
  end

  reaper.SetMediaTrackInfo_Value(track, "B_MUTE", 0)
  reaper.GetSet_LoopTimeRange(true, false, probe_start, scan_end, false)
  reaper.SetOnlyTrackSelected(track)
  reaper.Main_OnCommand(CMD_RENDER_SELECTED_AREA_TO_STEREO_STEM, 0)

  reaper.SetMediaTrackInfo_Value(track, "B_MUTE", temporary.source_mute)
  temporary.source_mute = nil

  for index = 0, reaper.CountTracks(0) - 1 do
    local candidate = reaper.GetTrack(0, index)
    if not existing_tracks[candidate] then
      temporary.measurement_track = candidate
      break
    end
  end
  if not temporary.measurement_track then
    error("REAPER did not create the temporary measurement stem.")
  end

  local item = reaper.GetTrackMediaItem(temporary.measurement_track, 0)
  if not item then
    error("The temporary measurement stem contains no rendered item.")
  end
  local take = reaper.GetActiveTake(item)
  if not take then
    error("The temporary measurement stem contains no active take.")
  end

  local source = reaper.GetMediaItemTake_Source(take)
  if source then
    local _, source_path = reaper.GetMediaSourceFileName(source, "")
    if source_path and source_path ~= "" then
      temporary.rendered_file_path = source_path
    end
  end

  return temporary.measurement_track, scan_end
end

local function analyse_post_fx_tail(
    measurement_track,
    probe_start,
    probe_end,
    scan_end
)
  local accessor = reaper.CreateTrackAudioAccessor(measurement_track)
  if not accessor then
    return nil, "REAPER could not create an audio accessor for the measurement."
  end

  local buffer = reaper.new_array(ANALYSIS_BLOCK_FRAMES * ANALYSIS_CHANNELS)
  local position = probe_start
  local first_audible
  local last_audible
  local read_failed = false

  while position < scan_end do
    local remaining_frames = math.ceil((scan_end - position) * ANALYSIS_SAMPLE_RATE)
    local frame_count = math.min(ANALYSIS_BLOCK_FRAMES, remaining_frames)
    buffer.clear()

    local available = reaper.GetAudioAccessorSamples(
      accessor,
      ANALYSIS_SAMPLE_RATE,
      ANALYSIS_CHANNELS,
      position,
      frame_count,
      buffer
    )
    -- REAPER returns 0 for a valid silent block and -1 for an actual error.
    if available < 0 then
      read_failed = true
      break
    end

    for frame = 0, frame_count - 1 do
      local sample_offset = frame * ANALYSIS_CHANNELS
      local peak = 0
      for channel = 1, ANALYSIS_CHANNELS do
        peak = math.max(peak, math.abs(buffer[sample_offset + channel]))
      end
      if peak >= SILENCE_THRESHOLD then
        local audible_time = position + frame / ANALYSIS_SAMPLE_RATE
        first_audible = first_audible or audible_time
        last_audible = audible_time
      end
    end

    position = position + frame_count / ANALYSIS_SAMPLE_RATE
  end

  reaper.DestroyAudioAccessor(accessor)

  if read_failed then
    return nil, "REAPER could not read the complete post-FX measurement."
  end
  if not first_audible then
    return nil,
      "The test signal produced no post-FX audio above "
      .. tostring(SILENCE_THRESHOLD_DB)
      .. " dBFS."
  end

  if scan_end - last_audible < SILENCE_HOLD_SECONDS then
    return nil,
      "The post-FX signal did not become silent within the five-second limit."
  end

  local measured_tail = math.max(0, last_audible - probe_end)
  local required_tail = measured_tail + SAFETY_SECONDS
  if required_tail > MAX_FREEZE_TAIL_SECONDS then
    return nil, string.format(
      "The measured response needs %.2f seconds including safety, "
      .. "which exceeds the five-second limit.",
      required_tail
    )
  end

  return required_tail
end

local function cleanup_measurement(source_track, temporary)
  if temporary.source_mute ~= nil
      and reaper.ValidatePtr2(0, source_track, "MediaTrack*") then
    reaper.SetMediaTrackInfo_Value(
      source_track,
      "B_MUTE",
      temporary.source_mute
    )
    temporary.source_mute = nil
  end
  if temporary.measurement_track
      and reaper.ValidatePtr2(0, temporary.measurement_track, "MediaTrack*") then
    reaper.DeleteTrack(temporary.measurement_track)
    temporary.measurement_track = nil
  end
  if temporary.probe_item
      and reaper.ValidatePtr2(0, temporary.probe_item, "MediaItem*")
      and reaper.ValidatePtr2(0, source_track, "MediaTrack*") then
    reaper.DeleteTrackMediaItem(source_track, temporary.probe_item)
    temporary.probe_item = nil
  end
  if temporary.time_start ~= nil and temporary.time_end ~= nil then
    reaper.GetSet_LoopTimeRange(
      true,
      false,
      temporary.time_start,
      temporary.time_end,
      false
    )
    temporary.time_start = nil
    temporary.time_end = nil
  end
  if temporary.rendered_file_path then
    os.remove(temporary.rendered_file_path)
    os.remove(temporary.rendered_file_path .. ".reapeaks")
    temporary.rendered_file_path = nil
  end
  if temporary.file_path then
    os.remove(temporary.file_path)
    temporary.file_path = nil
  end
end

local function measure_tail(track)
  local material_end = get_material_end(track)
  if not material_end then
    return nil,
      "The track and its upstream routing contain no media items, "
      .. "so the material end is undefined."
  end

  local temporary = {}
  local tail_seconds
  local measurement_error

  local ok, runtime_error = xpcall(function()
    local is_instrument = reaper.TrackFX_GetInstrument(track) >= 0
    local probe_end
    if is_instrument then
      probe_end = add_midi_probe(track, material_end, temporary)
    else
      probe_end = add_audio_probe(track, material_end, temporary)
    end

    reaper.TrackList_AdjustWindows(false)
    reaper.UpdateArrange()
    local measurement_track, scan_end =
      render_probe_window(track, material_end, probe_end, temporary)
    tail_seconds, measurement_error =
      analyse_post_fx_tail(
        measurement_track,
        material_end,
        probe_end,
        scan_end
      )
  end, debug.traceback)

  cleanup_measurement(track, temporary)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()

  if not ok then
    return nil, runtime_error
  end
  return tail_seconds, measurement_error
end

local selected_tracks = collect_selected_tracks()
if #selected_tracks == 0 then
  show_message("Select at least one track.")
  return
end

if not reaper.SNM_GetIntConfigVar or not reaper.SNM_SetIntConfigVar then
  show_message(
    "Smart Freeze Toggle requires the free SWS/S&M extension.\n\n"
    .. "Install SWS, restart REAPER, and run the script again."
  )
  return
end

local original_render_tail = reaper.SNM_GetIntConfigVar(
  RENDER_TAIL_CONFIG_KEY,
  -1
)
if original_render_tail < 0 then
  show_message("Could not read REAPER's freeze-tail preference.")
  return
end

local warnings = {}
local current_tail = original_render_tail

local function set_render_tail(milliseconds)
  if current_tail ~= milliseconds then
    reaper.SNM_SetIntConfigVar(RENDER_TAIL_CONFIG_KEY, milliseconds)
    current_tail = milliseconds
  end
end

reaper.Undo_BeginBlock2(0)
reaper.PreventUIRefresh(1)

local overall_ok, overall_error = xpcall(function()
  for _, track in ipairs(selected_tracks) do
    if reaper.ValidatePtr2(0, track, "MediaTrack*") then
      reaper.SetOnlyTrackSelected(track)

      local freeze_count = reaper.GetMediaTrackInfo_Value(track, "I_FREEZECOUNT")
      if freeze_count > 0 then
        reaper.Main_OnCommand(CMD_UNFREEZE_TRACKS, 0)
      else
        -- Keep the diagnostic render bounded to the five-second scan window,
        -- regardless of the user's normal render-tail preference.
        set_render_tail(0)
        local tail_seconds, measurement_error = measure_tail(track)
        if tail_seconds then
          local tail_milliseconds = math.ceil(tail_seconds * 1000)
          set_render_tail(tail_milliseconds)
          reaper.SetOnlyTrackSelected(track)
          reaper.Main_OnCommand(CMD_FREEZE_TO_STEREO, 0)

          if reaper.GetMediaTrackInfo_Value(track, "I_FREEZECOUNT") <= freeze_count then
            warnings[#warnings + 1] =
              track_name(track) .. ": REAPER did not complete the freeze."
          end
        else
          warnings[#warnings + 1] =
            track_name(track) .. ": " .. tostring(measurement_error)
        end
      end
    end
  end
end, debug.traceback)

set_render_tail(original_render_tail)
restore_track_selection(selected_tracks)
reaper.PreventUIRefresh(-1)
reaper.TrackList_AdjustWindows(false)
reaper.UpdateArrange()
reaper.Undo_EndBlock2(0, SCRIPT_NAME, -1)

if not overall_ok then
  warnings[#warnings + 1] = "Unexpected error:\n" .. tostring(overall_error)
end

if #warnings > 0 then
  show_message(
    "Some tracks were left unchanged:\n\n• " .. table.concat(warnings, "\n\n• ")
  )
end
