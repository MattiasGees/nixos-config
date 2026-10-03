-- Prints Spotify's now-playing state for items/media.lua, one field per line:
--   state, title, artist, artwork url, position (s), duration (s), track id
-- or just "stopped". The "is running" guard keeps it from launching Spotify.
-- Times are whole seconds so the output is locale-independent.
if application "Spotify" is running then
	tell application "Spotify"
		if player state is stopped then return "stopped"
		set t to current track
		return (player state as text) & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (artwork url of t) & linefeed & ((player position as integer) as text) & linefeed & (((duration of t) div 1000) as text) & linefeed & (id of t)
	end tell
end if
return "stopped"
