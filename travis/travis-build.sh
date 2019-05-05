#! /bin/bash

set -x
set -e

if [ "$ARCH" == "" ]; then
    echo "Error: \$ARCH not set"
    exit 1
fi

TEMP_BASE=/tmp

BUILD_DIR=$(mktemp -d -p "$TEMP_BASE" appimaged-build-XXXXXX)

cleanup () {
    if [ -d "$BUILD_DIR" ]; then
        rm -rf "$BUILD_DIR"
    fi
}

trap cleanup EXIT

# store repo root as variable
REPO_ROOT=$(readlink -f $(dirname $(dirname $0)))
OLD_CWD=$(readlink -f .)

if [ "$CI" != "" ] && [ "$KEY" != "" ]; then
    # clean up and download data from GitHub
    # don't worry about removing those data -- they'll be removed by the exit hook
    wget https://github.com/AppImage/AppImageKit/files/584665/data.zip -O data.tar.gz.gpg
    set +x ; echo "$KEY" | gpg2 --batch --passphrase-fd 0 --no-tty --skip-verify --output data.tar.gz --decrypt data.tar.gz.gpg || true
    tar xf data.tar.gz
    chown -R "$USER" .gnu*/
    chmod 0700 .gnu*/
    export GNUPGHOME=$(readlink -f .gnu*/)
fi

pushd "$BUILD_DIR"

## build up-to-date version of CMake
#wget https://cmake.org/files/v3.12/cmake-3.12.0.tar.gz -O- | tar xz
#pushd cmake-*/
#./configure --prefix="$BUILD_DIR"/bin
#make install -j$(nproc)
#popd
#
#export PATH="$BUILD_DIR"/bin:"$PATH"

if [ "$ARCH" == "i386" ]; then
    export EXTRA_CMAKE_ARGS=("-DCMAKE_TOOLCHAIN_FILE=$REPO_ROOT/cmake/toolchains/i386-linux-gnu.cmake")
fi

cmake "$REPO_ROOT" -DCMAKE_INSTALL_PREFIX=/usr "${EXTRA_CMAKE_ARGS[@]}"

make -j$(nproc)

# make .deb
cpack -V -G DEB

# make .rpm
cpack -V -G RPM

# make AppImages
mkdir -p appdir
make install DESTDIR=appdir

# Add "hidden" dependencies; https://github.com/AppImage/libappimage/issues/104
# We need a newer patchelf with '--add-needed'
git clone -o e1e39f3 https://github.com/NixOS/patchelf
cd patchelf
bash ./bootstrap.sh
./configure --prefix=/usr
make -j$(nproc)
sudo make install
cd -
patchelf --add-needed librsvg-2.so.2 --add-needed libcairo.so.2 --add-needed libgobject-2.0.so ./appdir/usr/bin/appimaged

# Workaround for:
# undefined symbol: g_type_check_instance_is_fundamentally_a
# Function g_type_check_instance_is_fundamentally_a was introduced in glib2-2.41.1
# Bundle libglib-2.0.so.0 - TODO: find a better solution, e.g., downgrade libglib-2.0 at compile time
mkdir -p ./appdir/usr/lib/
cp $(ldconfig -p | grep libglib-2.0.so.0 | head -n 1 | cut -d ">" -f 2 | xargs) ./appdir/usr/lib/
# The following come with glib2 and probably need to be treated together:
cp $(ldconfig -p | grep libgio-2.0.so.0 | head -n 1 | cut -d ">" -f 2 | xargs) ./appdir/usr/lib/
cp $(ldconfig -p | grep libgmodule-2.0.so.0 | head -n 1 | cut -d ">" -f 2 | xargs) ./appdir/usr/lib/
cp $(ldconfig -p | grep libgobject-2.0.so.0 | head -n 1 | cut -d ">" -f 2 | xargs) ./appdir/usr/lib/
cp $(ldconfig -p | grep libgthread-2.0.so.0 | head -n 1 | cut -d ">" -f 2 | xargs) ./appdir/usr/lib/

wget https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-"$ARCH".AppImage
chmod +x linuxdeploy-"$ARCH".AppImage
./linuxdeploy-"$ARCH".AppImage --appimage-extract
mv squashfs-root/ linuxdeploy/

linuxdeploy/AppRun --list-plugins

export UPDATE_INFORMATION="gh-releases-zsync|AppImage|appimaged|continuous|appimaged*$ARCH*.AppImage.zsync"
export SIGN=1
export VERBOSE=1
linuxdeploy/AppRun --appdir appdir --output appimage

mv appimaged*.{AppImage,deb,rpm}* "$OLD_CWD/"
