#!/bin/sh

# the base directory
BASE_DIR="$(pwd)"

# the directory for built packages tarballs
BINARY_TARBALL_DIR="$BASE_DIR/built_packages"

# uneeded files which should be removed from packages
UNNEEDED_FILES="usr/share/applications
                usr/share/info
                usr/share/gtk-doc
                lib/charset.alias
                etc/X11
                usr/share/gnome
                etc/init.d
                etc/udev
                usr/share/aclocal"

# include the configuration file
. ./config

# prepare the build environment
export AR
export CFLAGS="$CFLAGS -I$SYSROOT/usr/include"
export LDFLAGS="$LDFLAGS -L$SYSROOT/lib"
export PKG_CONFIG_PATH="$SYSROOT/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="/lib/pkgconfig"
export MAKE="make -j $(cat /proc/cpuinfo | grep ^processor | wc -l)"
export KARCH
export BASE_DIR
export SYSROOT
export PATH="$BASE_DIR:$PATH"
export LANG="C"
export LC_ALL="C"

# replace pkg-config with a wrapper which forces "--static"
if [ 1 -eq $STATIC ] && [ -d "$SYSROOT/lib/pkgconfig" ] && [ ! -f pkg-config ]
then
	echo "#!/bin/sh
exec $(which pkg-config) --static \"\$@\" | sed -e s~'-L/lib'~\"-L$SYSROOT/lib\"~g -e s~'-I/usr'~\"-I$SYSROOT/usr\"~g -e s~'-I/lib'~\"-I$SYSROOT/lib\"~g" > pkg-config
	chmod 755 pkg-config
fi

# replace glib-config, gtk-config, freetype-config, gdk-pixbuf-config and
# xml2-config with wrappers, which prepend paths with $SYSROOT
for library in glib gtk freetype gdk-pixbuf gdk-pixbuf xml2
do
	if [ -f "$SYSROOT/bin/$library-config" ] && [ ! -f $library-config ]
	then
		echo "#!/bin/sh
\"$SYSROOT/bin/$library-config\" \"\$@\" | sed -e s~'-L/lib'~\"-L$SYSROOT/lib\"~g -e s~'-I/usr'~\"-I$SYSROOT/usr\"~g -e s~'-I/lib'~\"-I$SYSROOT/lib\"~g" \
		> $library-config
		chmod 755 $library-config
	fi
done
export GLIB_CONFIG="$BASE_DIR/glib-config"
export GTK_CONFIG="$BASE_DIR/gtk-config"

# if musl is already installed, use its wrapper instead of the real compiler
if [ -e "musl-gcc" ]
then
	export REALGCC="$CC"
	export CC="$BASE_DIR/musl-gcc"
else
	# otherwise, build musl with the compiler specified in the configuration
	export CC
fi

# choose the library type flags passed to configure scripts
if [ 1 -eq $STATIC ]
then
	CONFIGURE_LIBRARY_FLAGS="--enable-static --disable-shared"
else
	CONFIGURE_LIBRARY_FLAGS="--disable-static --enable-shared"
fi

# make sure the package name is valid
if [ ! -e ./packages/$1.sh ]
then
    echo "Invalid package name"
    exit 1
fi

# include the build script
. ./packages/$1.sh

# create a directory for the package sources
mkdir -p ./sources/$1

# create a sandbox directory for building packages
[ ! -d build ] && mkdir build

# download the package source files
for i in $PACKAGE_SOURCES
do
	case "$i" in
		# if an output file was specified, separate it from the URL
		*,*)
			destination="${i##*,}"
			url="${i%%,*}"
			;;

		# otherwise, filter the output file name from the URL
		*)
			destination="${i##*/}"
			url="$i"
			;;
	esac

	# download the file
	if [ ! -f "./sources/$1/$destination" ]
	then
		case "$i" in
			ftp://*|http://*|https://*)
				wget "$url" -O "./sources/$1/$destination"
				;;

			svn://*)
				temporary_diretcory="$(mktemp -d)"
				cd "$temporary_diretcory"
				output_directory="$(basename "$destination" .tar.xz)"
				svn co $url "$output_directory"
				tar -c "$output_directory" | \
				xz -9 -e > "$BASE_DIR/sources/$1/$destination"
				rm -rf "$temporary_diretcory"
				cd "$BASE_DIR"
				;;
		esac
	fi

    # create a link to the file
	[ ! -e "build/$destination" ] && \
	                                   ln -s "../sources/$1/$destination" build/
done

# build the package
cd build
${1}_build

# install the package to a directory
installation_prefix="$(mktemp -d)"
${1}_package "$installation_prefix"

# remove all unneeded files
for i in $UNNEEDED_FILES
do
	[ -e "$installation_prefix/$i" ] && rm -rf "$installation_prefix/$i"
done

# remove libtool libraries
[ -d "$installation_prefix/lib" ] && rm -vf "$installation_prefix/lib"/*.la

# strip all executables, unless they were built in debug mode
should_strip=1
for flag in $CFLAGS
do
	if [ "-g" = "$flag" ]
	then
		should_strip=0
		break
	fi
done
if [ 1 -eq $should_strip ] && [ -d "$installation_prefix/bin" ]
then
	find "$installation_prefix" | while read file
	do
		[ "application/x-executable" = "$(file -b --mime-type "$file")" ] && \
		                                            "$STRIP" --strip-all "$file"
	done
fi

# strip all kernel modules
if [ -d "$installation_prefix/lib/modules" ]
then
	find "$installation_prefix/lib/modules" -name '*.ko' -type f |
	while read module
	do
		"$STRIP" --strip-unneeded "$module"
	done
fi

# decompress all compressed man pages
if [ -d "$installation_prefix/usr/share/man" ]
then
	find "$installation_prefix/usr/share/man" -name '*.gz' -type f |
	while read page
	do
		gunzip "$page"
	done
fi

# remove font cache files
if [ -d "$installation_prefix/usr/share/fonts" ]
then
	for i in "$installation_prefix/usr/share/fonts"/*
	do
		[ -f "$i/fonts.dir" ] && rm -f "$i/fonts.dir"
	done
fi

# create a tarball from the built package
[ ! -d "$BINARY_TARBALL_DIR" ] && mkdir -p "$BINARY_TARBALL_DIR"
tar -C "$installation_prefix" -c . | xz -9 -e \
                                 > "$BINARY_TARBALL_DIR/$1-$PACKAGE_VERSION.txz"

# remove the temporary installation directory
rm -rf "$installation_prefix"

# create the file system root directory
[ ! -d "$SYSROOT" ] && mkdir -p "$SYSROOT"

# install the package into the file system root
cd "$SYSROOT"
tar -xJvf "$BINARY_TARBALL_DIR/$1-$PACKAGE_VERSION.txz"
