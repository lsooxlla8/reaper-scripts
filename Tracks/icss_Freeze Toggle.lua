-- @description Freeze Toggle
-- @author lsooxlla8
-- @version 1.0.0
-- @changelog
--   Initial release
-- @about
--   Toggles the freeze state of every selected track.
--
--   * Unfrozen track: freeze to stereo.
--   * Frozen track: unfreeze one freeze layer.
--   * Mixed multi-track selections are processed independently.
--   * The original track selection is restored afterwards.

local CMD_FREEZE_TO_STEREO = 41223
local CMD_UNFREEZE_TRACKS = 41644

local selected_count = reaper.CountSelectedTracks(0)

if selected_count == 0 then
  reaper.ShowMessageBox(
    "Select at least one track.",
    "Smart Freeze Toggle",
    0
  )
  return
end

-- Keep the original selection. Processing tracks one at a time also makes a
-- mixed selection safe: frozen tracks are unfrozen, while unfrozen tracks are
-- frozen instead of adding another freeze layer to every selected track.
local selected_tracks = {}
for index = 0, selected_count - 1 do
  selected_tracks[#selected_tracks + 1] = reaper.GetSelectedTrack(0, index)
end

for _, track in ipairs(selected_tracks) do
  reaper.SetOnlyTrackSelected(track)

  local freeze_count = reaper.GetMediaTrackInfo_Value(track, "I_FREEZECOUNT")
  if freeze_count > 0 then
    reaper.Main_OnCommand(CMD_UNFREEZE_TRACKS, 0)
  else
    reaper.Main_OnCommand(CMD_FREEZE_TO_STEREO, 0)
  end
end

-- Restore the selection the user had before running the script.
reaper.SetOnlyTrackSelected(selected_tracks[1])
for index = 2, #selected_tracks do
  reaper.SetTrackSelected(selected_tracks[index], true)
end

reaper.TrackList_AdjustWindows(false)
reaper.UpdateArrange()
