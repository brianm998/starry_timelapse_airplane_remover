#!/bin/bash

# die on any error
set -e

# take release compiled gui and cli app and package them for distribution
# as well as tag this release in git with the version from Config.swift

GUI_APP="gui/.build/AdHoc/ntar.app" 
CLI_APP="cli/.build/apple/Products/Release/ntar"
NTAR_VERSION=`cd NtarCore ; perl version.pl`
TEMP_DIR="$$_RELEASE_TEMP"
TEMP_ZIP_BASE="${TEMP_DIR}/ntar-${NTAR_VERSION}"

# make a temp dir
mkdir -p $TEMP_ZIP_BASE

# copy the cli app to it
cp $CLI_APP $TEMP_ZIP_BASE

# Add README.md to it 
cp README.md $TEMP_ZIP_BASE

# add a real basic install.sh to it
cat > "${TEMP_ZIP_BASE}/install.sh"  <<EOF
#!/bin/bash

set -e

# add something here to tell the user what's going on,
# maybe a screen with text prompting the user to continue

echo 'Welcome to the ntar ${NTAR_VERSION} installer.'
echo
echo 'Do you wish to install ntar now?'
echo 'You will be prompted for an admistrator password during installation'
echo
echo -n 'enter 'y' to continue: '

read continue

if [ \$continue == "y" ]
then     
    unzip ntar-gui-${NTAR_VERSION}.zip >/dev/null
    sudo rm -rf /Applications/ntar.app
    sudo mv ntar.app /Applications
    sudo mv ntar /usr/local/bin
    rm ntar-gui-${NTAR_VERSION}.zip
    
    echo
    echo 'ntar ${NTAR_VERSION} has been installed.'
    echo
    echo 'I hope you enjoy ntar'
    echo
    echo '/usr/local/bin/ntar is at your service on the command line'
    echo 'open /Applications/ntar.app for the gui'
else
    echo "not installing ntar ${NTAR_VERSION} right now"
fi
EOF

chmod 755 "${TEMP_ZIP_BASE}/install.sh"

# copy the gui app to it, without this the gatekeeper gets angry
ditto \
    -c -k --sequesterRsrc --keepParent \
    $GUI_APP \
    "${TEMP_ZIP_BASE}/ntar-gui-${NTAR_VERSION}.zip"

# zip up the temp dir into to a named zip file in the releases dir
cd $TEMP_DIR
pwd 
zip -r "../releases/ntar-${NTAR_VERSION}.zip" "ntar-${NTAR_VERSION}"
cd ..

# delete temp dir
rm -rf $TEMP_DIR

# tag this release in the local repo
git tag "release/${NTAR_VERSION}"

# push that tag remote
git push origin "release/${NTAR_VERSION}"

# named zip file of this release is now in releases dir

echo "git tag releases/${NTAR_VERSION} created and pushed to remove"
echo "releases/ntar-${NTAR_VERSION}.zip file created"
