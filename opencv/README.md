## opencv is a pain to compile



### need c++ 17

add

set(CMAKE_CXX_STANDARD 17) ## HACK HACK

to the top of CMakeLists.txt

### need macos 10.14+

update platforms/osx/build_framework.py:

MACOSX_DEPLOYMENT_TARGET='14'  # default, can be changed via command line options or environment variable

### need to make sure to use apple's libtool, not homebrew's

same command, kindof, but /usr/bin/libtool is the one that works.

