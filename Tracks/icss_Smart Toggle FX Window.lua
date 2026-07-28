-- @description Smart Toggle FX Window
-- @author icanseesounds
-- @version 2.3.0
-- @changelog
--   Initial ReaPack release
-- @about
--   Toggles the FX window of the selected track.
--
--   * Closed window: close all track FX windows, then open its FX chain.
--   * Open window: close all track FX windows.
--   * Supports normal tracks, the master track, and floating FX.

local EXT_SECTION = "SmartToggleFXWindows"
local EXT_KEY = "EmptyTrackFXWindow"

local function get_track_key(track)
  if track == reaper.GetMasterTrack(0) then
    return "MASTER"
  end

  return reaper.GetTrackGUID(track)
end

local function get_remembered_track_key()
  local retval, value = reaper.GetProjExtState(0, EXT_SECTION, EXT_KEY)
  if retval == 1 then
    return value
  end

  return ""
end

local function set_remembered_track_key(value)
  reaper.SetProjExtState(0, EXT_SECTION, EXT_KEY, value or "")
end

local function is_track_fx_open(track)
  if not track then
    return false
  end

  -- Check the regular FX chain window.
  if reaper.TrackFX_GetChainVisible(track) ~= -1 then
    return true
  end

  -- Check individual floating plug-in windows.
  for fx_index = 0, reaper.TrackFX_GetCount(track) - 1 do
    if reaper.TrackFX_GetOpen(track, fx_index) then
      return true
    end
  end

  return false
end

local function close_all_track_fx(track)
  if not track then
    return
  end

  -- Close the FX chain or Add FX window.
  reaper.TrackFX_Show(track, 0, 0)

  -- Close individual floating plug-in windows.
  for fx_index = 0, reaper.TrackFX_GetCount(track) - 1 do
    reaper.TrackFX_SetOpen(track, fx_index, false)
  end
end

local function get_selected_track_including_master()
  local master_track = reaper.GetMasterTrack(0)
  if reaper.IsTrackSelected(master_track) then
    return master_track
  end

  return reaper.GetSelectedTrack(0, 0)
end

local function main()
  local selected_track = get_selected_track_including_master()
  if not selected_track then
    return
  end

  local selected_key = get_track_key(selected_track)
  local remembered_key = get_remembered_track_key()
  local selected_was_open = is_track_fx_open(selected_track)

  -- REAPER does not report an open FX chain on an empty track, so remember
  -- empty-track windows opened by this script.
  if reaper.TrackFX_GetCount(selected_track) == 0
      and remembered_key == selected_key then
    selected_was_open = true
  end

  reaper.PreventUIRefresh(1)

  close_all_track_fx(reaper.GetMasterTrack(0))
  for track_index = 0, reaper.CountTracks(0) - 1 do
    close_all_track_fx(reaper.GetTrack(0, track_index))
  end

  set_remembered_track_key("")

  if not selected_was_open then
    reaper.TrackFX_Show(selected_track, 0, 1)

    if reaper.TrackFX_GetCount(selected_track) == 0 then
      set_remembered_track_key(selected_key)
    end
  end

  reaper.PreventUIRefresh(-1)
end

main()
