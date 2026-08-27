on run argv
  set targetId to item 1 of argv
  tell application "iTerm2"
    activate
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          if id of s is targetId then
            select t
            select s
            select w
            return "focused"
          end if
        end repeat
      end repeat
    end repeat
  end tell
  return "not found"
end run
