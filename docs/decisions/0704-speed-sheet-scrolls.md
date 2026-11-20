# 0704: the speed sheet scrolls, its buttons do not

The sheet was a fixed VStack of about 650-700 pt, taller than the 681 pt test window, so Cancel was off screen. We put the body in a ScrollView with a fixed 400 pt height (a flexible ScrollView collapses in a sheet) and keep the buttons outside it. Rejected: shrinking text further, which breaks again with longer translations.
