# 0494: startup pictures are sized to the pane they sit in

Run 43912477865 showed the art redo made three mac gui startup screens too big for their space. Pictures keep their identity but are drawn smaller (150 pt choice pictures, 80 pt beside the speed text); Advanced gets `fixedSize` and `layoutPriority(1)` so no art can squeeze it again. Assertions are unchanged.
