### FFmpeg

Here are some files to enable an easy build of FFmpeg on macos.

This enables muxer_codecs.c to be compiled so that FFmpegMuxer.swift can be generated.

#### build.sh

First, clone FFmpeg source code

Then, copy build.sh, build_tool.sh and muxer_codecs.c to the root level.

then run build.sh, may take awhile.

Afterwards, build_tool.sh shoul work