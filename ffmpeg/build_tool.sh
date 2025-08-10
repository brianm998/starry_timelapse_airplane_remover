# first run ./build.sh

export PKG_CONFIG_PATH="$PWD/ffmpeg-build/lib/pkgconfig:$PKG_CONFIG_PATH"
gcc muxer_codecs.c -o muxer_codecs $(pkg-config --cflags --libs libavformat libavcodec libavutil)

#./muxer_codecs > ~/git/nighttime_timelapse_airplane_remover/StarCore/Sources/StarCore/FFmpegMuxer.swift 
