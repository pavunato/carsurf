on run argv
    set helper to item 1 of argv
    set hostName to item 2 of argv
    set tapX to item 3 of argv
    set tapY to item 4 of argv
    set swipeX to item 5 of argv
    set bottomY to item 6 of argv
    set topY to item 7 of argv
    tell application "CarPlay Simulator" to activate
    tell application "System Events" to tell process "CarPlay Simulator" to set frontmost to true
    log "Launching YouTube at " & (current date as text)
    do shell script "ssh -o BatchMode=yes -o ConnectTimeout=10 " & quoted form of hostName & " '/var/jb/usr/local/bin/carsurf-launch com.google.ios.youtube'"
    delay 3
    log "Click video at " & tapX & "," & tapY & " at " & (current date as text)
    do shell script quoted form of helper & " " & tapX & " " & tapY & " " & tapY & " 0.08"
    delay 3
    log "Swipe up at " & (current date as text)
    do shell script quoted form of helper & " " & swipeX & " " & bottomY & " " & topY & " 0.4"
    delay 3
    log "Swipe down at " & (current date as text)
    do shell script quoted form of helper & " " & swipeX & " " & topY & " " & bottomY & " 0.4"
    delay 3
    log "Input sequence completed at " & (current date as text)
end run
