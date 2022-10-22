#!/bin/bash

rm marked_airplane_data/*/*.csv
find marked_airplane_data -name 'layer_mask.tif' -exec echo '.build/x86_64-apple-macosx/debug/ntar' '{}' '&' ';' > /tmp/$$_foo
bash /tmp/$$_foo
rm /tmp/$$_foo
echo done
