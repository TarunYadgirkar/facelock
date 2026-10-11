# vhs docs/calibrate.tape  (from the repo root; reads your enrollment, never opens the camera)
Output assets/generated/facelock-calibrate.gif
Set Shell "bash"
Set FontSize 20
Set Width 1100
Set Height 250
Set Padding 28
Set Theme "Catppuccin Latte"
Set TypingSpeed 45ms
Hide
Type "export PS1='$ ' && alias facelock=$PWD/.venv/bin/facelock && clear"
Enter
Show
Sleep 600ms
Type "facelock calibrate"
Sleep 400ms
Enter
Sleep 4.5s
