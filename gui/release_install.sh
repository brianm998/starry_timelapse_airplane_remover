#!/bin/bash

STAR_VERSION=`cd ../StarCore ; perl version.pl`

./release.sh && open ".build/star_app_${STAR_VERSION}.pkg"
