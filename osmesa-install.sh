#!/bin/bash -e

# capture elapsed time - reset BASH time counter
SECONDS=0
# this script
scriptdir=$(cd $(dirname ${BASH_SOURCE[0]}); pwd)
scriptname=$(basename ${BASH_SOURCE[0]} .sh)
# get script path: credit: https://stackoverflow.com/questions/59895/getting-the-source-directory-of-a-bash-script-from-within/179231#179231
scriptpath="${BASH_SOURCE[0]}";
if ([ -h "${scriptpath}" ]) then
  while([ -h "${scriptpath}" ]) do scriptpath=`readlink "${scriptpath}"`; done
fi
pushd . > /dev/null
cd `dirname ${scriptpath}` > /dev/null
scriptpath=`pwd`;
popd  > /dev/null
# confirm is not being run from its location
if [ "$scriptpath" == "$PWD" ]; then 
	echo "CRITICAL: Do not run this script from its location!"
	echo "          Create and enter a subdirectory, then run."
	echo "            $ mkdir build; cd build"
	echo "            $ ../$scriptname.sh"
	exit
fi 

# environment variables used by this script:
# - OSMESA_PREFIX: where to install osmesa (must be writable)
# - OSMESA_VERSION: mesa version (set to the latest version by default)
# - LLVM_PREFIX: where llvm is / should be installed
# - LLVM_VERSION: llvm version (set to the latest version by default)
# - LLVM_BUILD: whether to build LLVM (0/1, 0 by default)
# - MACOSX_DEPLOYMENT_TARGET: minimun MacOSX SDK version (10.8 by default)
# - OSX_SDKSYSROOT: specify the location or name of OSX SDK (0/<sdk full path>, 0 by default)
# - MKJOBS: number of parallel make jobs (4 by default)
# - IGNORE_DEMO: do not download, build and run the MESA demo (0/1, 0 by default)
# - SILENT_LOG: redirect output and error to log file (0/1, 0 by default)

# - variables above can be edited directy in the script or from the command line
# - an example using the command-line "env SILENT_LOG=1 LLVM_BUILD=1 ../osmesa-install.sh"
# - Note: for OSX_SDKSYSROOT, do not include 'isysroot' on the command line - added by the script

# - other variable below, like 'clean', and 'interactive' can only be edited directly in the script.

# prefix to the osmesa installation
osmesaprefix="${OSMESA_PREFIX:-/opt/osmesa}"
# mesa version (default is latest version)
mesaversion="${OSMESA_VERSION:-17.1.4}"
# the prefix to the LLVM installation
llvmprefix="${LLVM_PREFIX:-/opt/llvm}"
# llvm version (default is latest version)
llvmversion="${LLVM_VERSION:-4.0.1}"
# do we want to build the proper LLVM static libraries too? or are they already installed ? (default is 0)
buildllvm="${LLVM_BUILD:-0}"
# set the minimum MacOSX SDK version (default is 10.8)
osxsdkminver="${MACOSX_DEPLOYMENT_TARGET:-10.8}"
# set isysroot <full path to sdk>, default sdk automatically set by script (default is 0)
osxsdkisysroot="${OSX_SDKSYSROOT:-0}"
# number of parallel make jobs, (default is 4)
mkjobs="${MKJOBS:-4}"
# set ignoredemo to 1 to not download, build and run the demo (default is 0)
ignoredemo="${IGNORE_DEMO:-0}"
# set silentlogging to 1 to redirect output and error to log file; exit script on error (default is 0)
silentlogging="${SILENT_LOG:-0}"
# mesa-demos version
demoversion=8.3.0
# glu version
gluversion=9.0.0
# set debug to 1 to compile a version with debugging symbols (default is 0)
debug=0
# set clean to 1 to clean the source directories first (recommended) (default is 1)
clean=1
# set interactive to 1 to confirm your selections or just execute (default is 0)
interactive=0
# set mangled to 1 to if you want a mangled mesa + GLU ? (default is 1)
mangled=1
# set osmesadriver to:
# - 1 to use "classic" osmesa resterizer instead of the Gallium driver
# - 2 to use the "softpipe" Gallium driver
# - 3 to use the "llvmpipe" Gallium driver (also includes the softpipe driver, which can
#     be selected at run-time by setting en var GALLIUM_DRIVER to "softpipe")
# - 4 to use the "swr" Gallium driver (also includes the softpipe driver, which can
#     be selected at run-time by setting en var GALLIUM_DRIVER to "softpipe") (default is 4)
osmesadriver=4
# set buildnonnativeargh to 1 to build 32bit libs on 64bit dev env and vice versa (non MacOS) (default is 0)
buildnonnativearch=0

# increment log file name
f="$scriptdir/$scriptname"
ext=".log"
if [[ -e "$f$ext" ]] ; then
    i=1
    f="${f%.*}";
    while [[ -e "${f}_${i}${ext}" ]]; do
        let i++
    done
    f="${f}_${i}${ext}"
else
   f="${f}${ext}"
fi
# output log file
logfile="$f"
# which OS platform
osname=`uname`
# which OS architecture
osnameprefix=`echo $osname | cut -c1-5`
if [ "$osnameprefix" = MSYS ] || [ "$osnameprefix" = MINGW ]; then
    # valid values: 64, 32; `uname -m` gives x86_64 for both 32bit and 64bit mingw options on 64bit machine
    nativearch=`echo $osname | cut -c6-7`
else
    # valid values: x86_64, i386
    nativearch=`uname -m`
fi

# MacOS particulars
origosmesadriver="$osmesadriver"
if [ "$osname" = Darwin ]; then
    if [ "$osmesadriver" = 4 ]; then
        #     "swr" (aka OpenSWR) is not supported on macOS,
        #     https://github.com/OpenSWR/openswr/issues/2
        #     https://github.com/OpenSWR/openswr-mesa/issues/11
        osmesadriver=3
    fi
    osver=$(uname -r | awk -F . '{print $1}')
    if [ "$osver" = 10 ]; then
        # On Snow Leopard, if using the system's gcci with libstdc++, build with llvm 3.4.2.
        # If using libc++ (see https://trac.macports.org/wiki/LibcxxOnOlderSystems), compile
        # everything with clang-4.0
        if grep -q -e '^cxx_stdlib.*libc\+\+' /opt/local/etc/macports/macports.conf; then
            CC=clang-mp-4.0
            CXX=clang++-mp-4.0
            OSDEMO_LD="clang++-mp-4.0 -stdlib=libc++"
        elif [ -z "${LLVM_VERSION+x}" ]; then
            llvmversion=3.4.2
        fi
    fi
fi
# MSYS particulars
# Do not build clang (LLVM) 4.0.0 if platform is 32bit mingw64 due to the following gcc bug
# http://lists.llvm.org/pipermail/cfe-dev/2016-December/052017.html
# https://gcc.gnu.org/bugzilla/show_bug.cgi?id=78936
origllvmversion="$llvmversion"
if [ "$buildllvm" = 1 ] && [ "$llvmversion" = 4.0.0 ] && [ "$osnameprefix" = MINGW ] && [ "$nativearch" = 32 ]; then
    llvmversion=3.9.1
fi

# functions
logquietly() {
	# Exit script on error, redirect output and error to log file. Open log for realtime updates.
	set -e
	exec </dev/null &>$logfile
}
echooptions() {
	# Echo and capture useful details about the build - helpful when reviewing the log file.
	echo "Mesa build options for platform $osname:"
	echo "- build date: `date '+%d/%m/%Y %H:%M:%S'`"
	if [ "$debug" = 1 ]; then
	    echo "- debug build"
	else
	    echo "- release, non-debug build"
	fi
	if [ "$mangled" = 1 ]; then
	    echo "- mangled (all function names start with mgl instead of gl)"
	else
	    echo "- non-mangled"
	fi
    if [ "$buildnonnativearch" = 1 ] && [ "$osname" != Darwin ]; then
        if [ "$nativearch" = x86_64 ] || [ "$nativearch" = 64 ]; then
            echo "- build 32bit (non-native) libraries"
        else
            echo "- build 64bit (non-native) libraries"
        fi
    fi
	if [ "$osmesadriver" = 1 ]; then
	    echo "- classic osmesa software renderer"
	elif [ "$osmesadriver" = 2 ]; then
		echo "- softpipe Gallium renderer"
	elif [ "$osmesadriver" = 3 ]; then
		echo "- llvmpipe Gallium renderer"
		if [ "$buildllvm" = 1 ]; then
			echo "- also build and install LLVM $llvmversion in $llvmprefix"
		fi
        if [ "$osmesadriver" -ne "$origosmesadriver" ]; then
            echo "- Note: renderer changed; swr is not supported on MacOS"
        fi        
	elif [ "$osmesadriver" = 4 ]; then
		echo "- swr Gallium renderer"
		if [ "$buildllvm" = 1 ]; then
			echo "- also build and install LLVM $llvmversion in $llvmprefix"
		fi
	else
	    echo "WARNING: invalid value detected for osmesadriver [$osmesadriver]"
		if [ "$osname" = Darwin ]; then
			osmesadriver=3
			echo "         using default option - llvmpipe Gallium renderer [$osmesadriver]"
		else
			osmesadriver=4
			echo "         using default option - swr Gallium renderer [$osmesadriver]"
		fi
	fi
	if [ "$clean" = 1 ]; then
		echo "- clean source before rebuild"
	else
		echo "- reuse built source at rebuild"
	fi
	if [ "$buildllvm" = 1 ]; then
		echo "- build llvm: Yes"
		echo "- llvm version: $llvmversion"
		echo "- llvm prefix: $llvmprefix"
        if [ "$llvmversion" != "$origllvmversion" ]; then
            "- Note: llvm (clang) version changed; version $llvmversion fails to build on $osname"
        fi
	else
		echo "- build llvm: No"
	fi
	echo "- mesa version: $mesaversion"
	echo "- osmesa prefix: $osmesaprefix"		
	echo "- glu version: $gluversion"
	if [ "$osmame" = Darwin ]; then
		echo "compiled for MacOX minimum version: $osxsdkminver"
		if [ "$osxsdkisysroot" != 0 ]; then
			echo "- user specified MacOSX isysroot: $osxsdkisysroot"
		elif [ ! -x "/usr/bin/xcrun" ]; then
		    echo "WARNING: Cannot automatically set isysroot SDK path."
		    echo "         Manually update this script at 'osxsdkisysroot'"
		    echo "         or set env variable OSX_SDKSYSROOT at execution." 
		fi
	fi
    if [ "$ignoredemo" = 1 ]; then
        echo "- execute osmesa demo: No"
    else
        echo "- execute osmesa demo: Yes"
    fi
	echo "- CC: $CC"
	echo "- CXX: $CXX"
	echo "- CFLAGS: $CFLAGS"
	echo "- CXXFLAGS: $CXXFLAGS"
	if [ "$osnameprefix" != MSYS ] && [ "$osnameprefix" != MINGW ]; then
		gccversion=`gcc -dumpversion`
		echo "- gcc version: $gccversion"
		cmakeversion=`cmake --version | sed -n '1p' | cut -d' ' -f 3`
		echo "- cmake version: $cmakeversion"
		autoconfversion=`autoconf --version | sed -n '1p' | cut -d' ' -f 4`
		echo "- autoconf version: $autoconfversion"	
	else
		msysversion=`pacman -Q -s msys | sed -n '1p' | cut -d' ' -f 2`
		echo "- msys version: $msysversion"
		mingwversion=`pacman -Q -s mingw | sed -n '1p' | cut -d' ' -f 2`
		echo "- mingw version: $mingwversion"
		gccversion=`pacman -Q -s gcc | sed -n '1p' | cut -d' ' -f 2`
		echo "- gcc version: $gccversion"
		cmakeversion=`pacman -Q -s cmake | sed -n '1p' | cut -d' ' -f 2`
		echo "- cmake version: $cmakeversion"
		sconsversion=`pacman -Q -s scons | sed -n '1p' | cut -d' ' -f 2`
		echo "- scons version: $sconsversion"
		bisonversion=`pacman -Q -s bison | sed -n '1p' | cut -d' ' -f 2`
		echo "- bison/yacc version: $bisonversion"
		pythonversion=`pacman -Q -s python2 | sed -n '1p' | cut -d' ' -f 2`
		echo "- python2 version: $pythonversion"
		makoversion=`pacman -Q -s python2-mako | sed -n '1p' | cut -d' ' -f 2`
		echo "- python2-mako version: $makoversion"
        libxml2version=`pacman -Q -s libxml2 | sed -n '1p' | cut -d' ' -f 2`
        echo "- libxml2 version: $libxml2version"
    fi
    if [ "$interactive" = 1 ]; then
        echo "- interactive: Yes"
    else
        echo "- interactive: No"
    fi
	if [ "$silentlogging" = 1 ]; then
		echo "- silent logging"
		echo "- log file: $logfile"
	else
		echo "- no logging"
	fi
}
confirmoptions() {
	# Review and confirm/cancel continuing the script
    echo
	echo "Enter n to exit or any key to continue."
	read -n 1 -p "Do you want to continue with these options? : " input
	echo
	if [ "$input" = "n" ] || [ "$input" = "N" ]; then
		echo "You have exited the script."
		exit
	else
		if [ "$silentlogging" = 1 ]; then
			clear
			echo "Processing..."
			echo "- Log File: $logfile"
		else
			echo "Processing..."
		fi
	fi
}

# tell curl to continue downloads and follow redirects
curlopts="-L -C -"
srcdir="$scriptdir"

if [ "$debug" = 1 ]; then
    CFLAGS="${CFLAGS:--g}"
else
    CFLAGS="${CFLAGS:--O3}"
fi
CXXFLAGS="${CXXFLAGS:-${CFLAGS}}"
if [ -z "${CC:-}" ]; then
    CC=gcc
fi
if [ -z "${CXX:-}" ]; then
    CXX=g++
fi
if [ "$osname" = Darwin ]; then
	# Possible $osver values:
	# 9: Mac OS X 10.5 Leopard
	# 10: Mac OS X 10.6 Snow Leopard
	# 11: Mac OS X 10.7 Lion
	# 12: OS X 10.8 Mountain Lion
	# 13: OS X 10.9 Mavericks
	# 14: OS X 10.10 Yosemite
	# 15: OS X 10.11 El Capitan
	# 16: macOS 10.12 Sierra
	# 17: macOS 10.13 High Sierra
	   
    if [ "$osver" = 10 ]; then
       # On Snow Leopard (10.6), build universal
       archs="-arch i386 -arch x86_64"
       CFLAGS="$CFLAGS $archs"
       CXXFLAGS="$CXXFLAGS $archs"
       ## uncomment to use clang 3.4 (not necessary, as long as llvm is not configured to be pedantic)
       #CC=clang-mp-3.4
       #CXX=clang++-mp-3.4
    fi
    XCODE_VER=$(xcodebuild -version | head -n 1 | sed -e 's/Xcode //')
    case "$XCODE_VER" in
		4.2*|5.*|6.*|7.*|8.*)
        # clang became the default compiler on Xcode 4.2
	    CC=clang
	    CXX=clang++
	    ;;
    esac
fi
if [ "$buildnonnativearch" = 1 ] && [ "$osname" != Darwin ]; then
	# option to build non-native architecture on platforms other than MacOS
    if [ "$nativearch" = x86_64 ]; then
        CFLAGS="$CFLAGS -m32"
        CXXFLAGS="$CXXFLAGS -m32"
    else
        CFLAGS="$CFLAGS -m64"
        CXXFLAGS="$CXXFLAGS -m64"
    fi
fi

# confirm options
if [ "$interactive" = 1 ]; then
    echooptions
    confirmoptions
fi
# write options to log
if [ "$silentlogging" = 1 ]; then
    logquietly
    echooptions
fi

# On MacPorts, building Mesa requires the following packages:
# sudo port install xorg-glproto xorg-libXext xorg-libXdamage xorg-libXfixes xorg-libxcb

llvmlibs=
if [ ! -d "$osmesaprefix" ] || [ ! -w "$osmesaprefix" ]; then
    echo "Error: $osmesaprefix does not exist or is not user-writable, please create $osmesaprefix and make it user-writable"
    exit
fi
if [ "$osmesadriver" = 3 ] || [ "$osmesadriver" = 4 ]; then
    # see also https://wiki.qt.io/Cross_compiling_Mesa_for_Windows
    if [ "$buildllvm" = 1 ]; then
        if [ ! -d "$llvmprefix" -o ! -w "$llvmprefix" ]; then
            echo "Error: $llvmprefix does not exist or is not user-writable, please create $llvmprefix and make it user-writable"
            exit
        fi
        # LLVM must be compiled with RRTI, see https://bugs.freedesktop.org/show_bug.cgi?id=90032
        if [ "$clean" = 1 ]; then
            rm -rf llvm-${llvmversion}.src
        fi

        archsuffix=xz
        xzcat=xzcat
        if [ $llvmversion = 3.4.2 ]; then
            archsuffix=gz
            xzcat="gzip -dc"
        fi
        # From Yosemite (14) gunzip can decompress xz files - but only if containing a tar archive.
        if [ "$osname" = Darwin ] && [ `uname -r | awk -F . '{print $1}'` -gt 13 ]; then
            xzcat="gunzip -dc"
        fi
        if [ ! -f llvm-${llvmversion}.src.tar.$archsuffix ]; then
			echo "* downloading LLVM ${llvmversion}..."
            # the llvm we server doesnt' allow continuing partial downloads
            curl $curlopts -O "http://www.llvm.org/releases/${llvmversion}/llvm-${llvmversion}.src.tar.$archsuffix"
        fi

        if [ ! -d llvm-${llvmversion}.src ]; then
            echo "* extracting LLVM..."
            $xzcat llvm-${llvmversion}.src.tar.$archsuffix | tar xf -
        fi
        cd llvm-${llvmversion}.src

		echo "* building LLVM..."

        cmake_archflags=
        if [ $llvmversion = 3.4.2 ] && [ "$osname" = Darwin ] && [ "$osver" = 10 ]; then
            if [ "$debug" = 1 ]; then
                debugopts="\
                --disable-optimized \
                --enable-debug-symbols \
                --enable-debug-runtime \
                --enable-assertions \
                "
            else
                debugopts="\
                --enable-optimized \
                --disable-debug-symbols \
                --disable-debug-runtime \
                --disable-assertions \
                "
            fi
            # On Snow Leopard, build universal
            # and use configure (as macports does)
            # workaround a bug in Apple's shipped gcc driver-driver
            if [ "$CXX" = "g++" ]; then
                echo "static int ___ignoreme;" > tools/llvm-shlib/ignore.c
            fi
            env CC="$CC" CXX="$CXX" REQUIRES_RTTI=1 UNIVERSAL=1 UNIVERSAL_ARCH="i386 x86_64" 
            ./configure \
            --prefix="$llvmprefix" \
            --enable-bindings=none \
            --disable-libffi \
            --disable-shared \
            --enable-static \
            --enable-jit \
            --enable-pic \
            --enable-targets=host \
            --disable-profiling \
            --disable-backtraces \
            --disable-terminfo \
            --disable-zlib \
            $debugopts
            env REQUIRES_RTTI=1 UNIVERSAL=1 UNIVERSAL_ARCH="i386 x86_64" 
            make -j${mkjobs}
            echo "* installing LLVM..."
            make install
         else
            cmakegen="Unix Makefiles" # will set to "MSYS Makefiles" on MSYS
            cmake_archflags=""
            llvm_patches=""
            if [ "$osname" = Darwin ] && [ "$osver" = 10 ]; then
                # On Snow Leopard, build universal
                cmake_archflags="-DCMAKE_OSX_ARCHITECTURES=i386;x86_64"
                # Proxy for eliminating the dependency on native TLS
                # http://trac.macports.org/ticket/46887
                #cmake_archflags="$cmake_archflags -DLLVM_ENABLE_BACKTRACES=OFF" # flag was added to the common flags below, we don't need backtraces anyway

                # https://llvm.org/bugs/show_bug.cgi?id=25680
                #configure.cxxflags-append -U__STRICT_ANSI__
            fi
            if [ "$osname" = Darwin ]; then
            	# if env var not set/using default setting
            	if [ ! -n "${MACOSX_DEPLOYMENT_TARGET+x}" ]; then
                	# Redundant - provided for older compilers that do not pass this option to the linker
                	env MACOSX_DEPLOYMENT_TARGET=$osxsdkminver
                fi
                # Address xcode/cmake error: compiler appears to require libatomic, but cannot find it.
                cmake_archflags="-DLLVM_ENABLE_LIBCXX=ON" 
                if [ "$osver" -ge 12 ]; then
                    # From Mountain Lion onward. We are only building 64bit arch.
                    cmake_archflags="$cmake_archflags -DCMAKE_OSX_ARCHITECTURES=x86_64"
				fi
				# Set minimum MacOSX deployment target
                cmake_archflags="$cmake_archflags -DCMAKE_OSX_DEPLOYMENT_TARGET=$osxsdkminver"
                # Set SDK sys root - necessary if user specified or different from CMake list default
                if [ "$osxsdkisysroot" != 0 ]; then
                	cmake_archflags="$cmake_archflags -DCMAKE_OSX_SYSROOT=$osxsdkisysroot"
                fi
            fi  
            if [ "$osnameprefix" = MSYS ] || [ "$osnameprefix" = MINGW ]; then
                cmakegen="MSYS Makefiles"
                #cmake_archflags="-DLLVM_ENABLE_CXX1Y=ON" # is that really what we want???????
                cmake_archflags="-DLLVM_USE_CRT_DEBUG=MTd -DLLVM_USE_CRT_RELEASE=MT"
                llvm_patches="msys2_add_pi.patch"
            fi
            for i in $llvm_patches; do
                if [ -f "$srcdir"/patches/llvm-$llvmversion/$i ]; then
                echo "* applying patch $i"
                patch -p1 -d . < "$srcdir"/patches/llvm-$llvmversion/$i
                fi
            done
            if [ ! -d build ]; then
                mkdir build
            fi
            cd build
            if [ "$debug" = 1 ]; then
                debugopts="\
                -DCMAKE_BUILD_TYPE=Debug \
                -DLLVM_ENABLE_ASSERTIONS=ON \
                -DLLVM_INCLUDE_TESTS=ON \
                -DLLVM_INCLUDE_EXAMPLES=ON \
                "
            else
                debugopts="\
                -DCMAKE_BUILD_TYPE=Release \
                -DLLVM_ENABLE_ASSERTIONS=OFF \
                -DLLVM_INCLUDE_TESTS=OFF \
                -DLLVM_INCLUDE_EXAMPLES=OFF \
                "
            fi
            env CC="$CC" CXX="$CXX" REQUIRES_RTTI=1 
            cmake -G "$cmakegen" .. \
            -DCMAKE_C_COMPILER="$CC" \
            -DCMAKE_CXX_COMPILER="$CXX" \
            -DCMAKE_INSTALL_PREFIX=${llvmprefix} \
            -DLLVM_TARGETS_TO_BUILD="host" \
            -DLLVM_ENABLE_RTTI=ON \
            -DLLVM_REQUIRES_RTTI=ON \
            -DBUILD_SHARED_LIBS=OFF \
            -DBUILD_STATIC_LIBS=ON \
            -DLLVM_ENABLE_FFI=OFF \
            -DLLVM_BINDINGS_LIST=none \
            -DLLVM_ENABLE_PEDANTIC=OFF \
            -DLLVM_INCLUDE_TESTS=OFF \
            -DLLVM_ENABLE_BACKTRACES=OFF \
            -DLLVM_ENABLE_TERMINFO=OFF \
            -DLLVM_ENABLE_ZLIB=OFF \
            $debugopts \
            $cmake_archflags
            env REQUIRES_RTTI=1 
            make -j${mkjobs}
			echo "* installing LLVM..."
            make install
            cd ..
        fi
        cd ..
        # elapsed llvm build time
        ELAPSED_LLVM="Elapsed: $(($SECONDS / 3600))hrs $((($SECONDS / 60) % 60))min $(($SECONDS % 60))sec"
        echo "* Library llvm-${llvmversion} build and install completed. Time $ELAPSED_LLVM"
    fi
    llvmconfigbinary=
    if [ "$osnameprefix" = MSYS ] || [ "$osnameprefix" = MINGW ]; then
        llvmconfigbinary="$llvmprefix/bin/llvm-config.exe"
    else
        llvmconfigbinary="$llvmprefix/bin/llvm-config"
    fi
    # Check if llvm installed
    if [ ! -x "$llvmconfigbinary" ]; then
        # could not find installation.  
        if [ "$buildllvm" = 0 ]; then
            # advise user to turn on automatic download, build and install option
            echo "Error: $llvmconfigbinary does not exist, set script variable buildllvm=\${LLVM_BUILD:-0} from 0 to 1 to automatically download and install llvm."
        else
            echo "Error: $llvmconfigbinary does not exist, please install LLVM with RTTI support in $llvmprefix"
            echo "       download the LLVM sources from llvm.org, and configure it with:" 
            echo "       env CC=$CC CXX=$CXX cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$llvmpref ix -DBUILD_SHARED_LIBS=OFF -DLLVM_ENABLE_RTTI=1 -DLLVM_REQUIRES_RTTI=1 -DLLVM_ENABLE_PEDANTIC=0  $cmake_archflags"
            echo "       env REQUIRES_RTTI=1 make -j${mkjobs}"
        fi
        exit
    fi
    llvmcomponents="engine mcjit"
    if [ "$debug" = 1 ]; then
        llvmcomponents="$llvmcomponents mcdisassembler"
    fi
    llvmlibs=$("${llvmconfigbinary}" --ldflags --libs $llvmcomponents)
    if "${llvmconfigbinary}" --help 2>&1 | grep -q system-libs; then
        llvmlibsadd=$("${llvmconfigbinary}" --system-libs)
    else
        # on old llvm, system libs are in the ldflags
        llvmlibsadd=$("${llvmconfigbinary}" --ldflags)
    fi
    llvmlibs="$llvmlibs $llvmlibsadd"
fi

if [ "$clean" = 1 ]; then
    rm -rf "mesa-$mesaversion" "mesa-demos-$demoversion" "glu-$gluversion"
fi

if [ ! -f "mesa-${mesaversion}.tar.gz" ]; then
    echo "* downloading Mesa ${mesaversion}..."
    curl $curlopts -O "ftp://ftp.freedesktop.org/pub/mesa/mesa-${mesaversion}.tar.gz" || curl $curlopts -O "ftp://ftp.freedesktop.org/pub/mesa/${mesaversion}/mesa-${mesaversion}.tar.gz"
fi

echo "* extracting Mesa..."

tar zxf mesa-${mesaversion}.tar.gz

# apply patches from MacPorts

echo "* applying patches..."

#add_pi.patch still valid with Mesa 17.0.3
#gallium-once-flag.patch only for Mesa < 12.0.1
#gallium-osmesa-threadsafe.patch still valid with Mesa 17.0.3
#glapi-getproc-mangled.patch only for Mesa < 11.2.2
#install-GL-headers.patch still valid with Mesa 17.0.3
#lp_scene-safe.patch still valid with Mesa 17.0.3
#mesa-glversion-override.patch
#osmesa-gallium-driver.patch still valid with Mesa 17.0.3
#redefinition-of-typedef-nirshader.patch only for Mesa 12.0.x
#scons25.patch only for Mesa < 12.0.1
#scons-llvm-3-9-libs.patch still valid with Mesa 17.0.3
#swr-sched.patch still valid with Mesa 17.0.3

PATCHES="\
add_pi.patch \
gallium-once-flag.patch \
gallium-osmesa-threadsafe.patch \
glapi-getproc-mangled.patch \
install-GL-headers.patch \
lp_scene-safe.patch \
mesa-glversion-override.patch \
osmesa-gallium-driver.patch \
redefinition-of-typedef-nirshader.patch \
scons25.patch \
scons-llvm-3-9-libs.patch \
swr-sched.patch \
scons-swr-cc-arch.patch \
msys2_scons_fix.patch \
"

#if mangled, add mgl_export (for mingw)
if [ "$mangled" = 1 ]; then
    PATCHES="$PATCHES mgl_export.patch"
fi

# mingw-specific patches (for maintainability, prefer putting everything in the main patch list)
#if [ "$osnameprefix" = MSYS ] || [ "$osnameprefix" = MINGW ]; then
#    PATCHES="$PATCHES "
#fi

if [ "$osname" = Darwin ]; then
    # patches for Mesa 12.0.1 from
    # https://github.com/macports/macports-ports/tree/master/x11/mesa/files
    PATCHES="$PATCHES \
    0001-mesa-Deal-with-size-differences-between-GLuint-and-G.patch \
    0002-applegl-Provide-requirements-of-_SET_DrawBuffers.patch \
    0003-glext.h-Add-missing-include-of-stddef.h-for-ptrdiff_.patch \
    5002-darwin-Suppress-type-conversion-warnings-for-GLhandl.patch \
    static-strndup.patch \
    no-missing-prototypes-error.patch \
    o-cloexec.patch \
    patch-include-GL-mesa_glinterop_h.diff \
    "
fi

for i in $PATCHES; do
    if [ -f "$srcdir"/patches/mesa-$mesaversion/$i ]; then
        echo "* applying patch $i..."
        patch -p1 -d mesa-${mesaversion} < "$srcdir"/patches/mesa-$mesaversion/$i
    fi
done

cd "mesa-${mesaversion}"

echo "* fixing gl_mangle.h..."
# edit include/GL/gl_mangle.h, add ../GLES*/gl[0-9]*.h to the "files" variable and change GLAPI in the grep line to GL_API
gles=
for h in GLES/gl.h GLES2/gl2.h GLES3/gl3.h GLES3/gl31.h GLES3/gl32.h; do
    if [ -f include/$h ]; then
        gles="$gles ../$h"
    fi
done
(cd include/GL; sed -e 's@gl.h glext.h@gl.h glext.h '"$gles"'@' -e 's@\^GLAPI@^GL_\\?API@' -i.orig gl_mangle.h)
(cd include/GL; sh ./gl_mangle.h > gl_mangle.h.new && mv gl_mangle.h.new gl_mangle.h)

echo "* fixing src/mapi/glapi/glapi_getproc.c..."
# functions in the dispatch table sre not stored with the mgl prefix
sed -i.bak -e 's/MANGLE/MANGLE_disabled/' src/mapi/glapi/glapi_getproc.c

echo "* building Mesa..."

if [ "$osnameprefix" = MSYS ] || [ "$osnameprefix" = MINGW ]; then

    ####################################################################
    # Windows build uses scons

    if [ "$buildnonnativearch" = 1 ]; then
        if [ "$nativearch" = 64 ]; then
            scons_machine="x86"
        else
            scons_machine="x86_64"
        fi
    else 
        if [ "$nativearch" = 64 ]; then
            scons_machine="x86_64"
        else
            scons_machine="x86"
        fi
    fi

    scons_cflags="$CFLAGS"
    scons_cxxflags="$CXXFLAGS -std=c++11"
    scons_ldflags="-static -s"
    if [ "$mangled" = 1 ]; then
        scons_cflags="-DUSE_MGL_NAMESPACE"
    fi
    if [ "$debug" = 1 ]; then
        scons_build="debug"
    else
        scons_build="release"
    fi
    if [ "$osmesadriver" = 3 ] || [ "$osmesadriver" = 4 ]; then
        scons_llvm=yes
    else
        scons_llvm=no
    fi
    if [ "$osmesadriver" = 4 ]; then
        scons_swr=1
    else
        scons_swr=0
    fi
    mkdir -p $osmesaprefix/include $osmesaprefix/lib/pkgconfig
    echo "** Mesa scons command line arguments..."
    echo "** env "
    echo "** LLVM_CONFIG=\"$llvmconfigbinary\""
    echo "** LLVM=\"$llvmprefix\""
    echo "** CFLAGS=\"$scons_cflags\""
    echo "** CXXFLAGS=\"$scons_cxxflags\""
    echo "** LDFLAGS=\"$scons_ldflags\""
    echo "** scons"
    echo "** build=\"$scons_build\""
    echo "** platform=windows"
    echo "** toolchain=mingw"
    echo "** machine=\"$scons_machine\""
    echo "** texture_float=yes"
    echo "** llvm=\"$scons_llvm\""
    echo "** swr=\"$scons_swr\""
    echo "** verbose=yes"
    echo "** osmesa"
    env LLVM_CONFIG="$llvmconfigbinary" LLVM="$llvmprefix" CFLAGS="$scons_cflags" CXXFLAGS="$scons_cxxflags" LDFLAGS="$scons_ldflags" scons build="$scons_build" platform=windows toolchain=mingw machine="$scons_machine" texture_float=yes llvm="$scons_llvm" swr="$scons_swr" verbose=yes osmesa
    cp build/windows-$scons_machine/gallium/targets/osmesa/osmesa.dll $osmesaprefix/lib/
    cp -a include/GL $osmesaprefix/include/ || exit 1
    cat <<EOF > $osmesaprefix/lib/pkgconfig/osmesa.pc
prefix=${osmesaprefix}
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: osmesa
Description: Mesa Off-screen Rendering library
Requires:
Version: $mesaversion
Libs: -L\${libdir} -lOSMesa
Cflags: -I\${includedir}
EOF
    cp $osmesaprefix/lib/pkgconfig/osmesa.pc $osmesaprefix/lib/pkgconfig/gl.pc

    # end of SCons build
    ####################################################################
else

    ####################################################################
    # Unix builds use configure

    test -f Mafefile && make -j${mkjobs} distclean # if in an existing build

    autoreconf -fi

    confopts="\
    --disable-dependency-tracking \
    --enable-static \
    --disable-shared \
    --enable-texture-float \
    --disable-gles1 \
    --disable-gles2 \
    --disable-dri \
    --disable-dri3 \
    --disable-glx \
    --disable-glx-tls \
    --disable-egl \
    --disable-gbm \
    --disable-xvmc \
    --disable-vdpau \
    --disable-omx \
    --disable-va \
    --disable-opencl \
    --disable-shared-glapi \
    --disable-driglx-direct \
    --with-dri-drivers= \
    --with-osmesa-bits=32 \
    --with-egl-platforms= \
    --prefix=$osmesaprefix \
    "

    if [ "$osmesadriver" = 1 ]; then
        # pure osmesa (swrast) OpenGL 2.1, GLSL 1.20
        confopts="${confopts} \
             --enable-osmesa \
             --disable-gallium-osmesa \
             --disable-gallium-llvm \
             --with-gallium-drivers= \
        "
    elif [ "$osmesadriver" = 2 ]; then
        # gallium osmesa (softpipe) OpenGL 3.0, GLSL 1.30
        confopts="${confopts} \
             --disable-osmesa \
             --enable-gallium-osmesa \
             --disable-gallium-llvm \
             --with-gallium-drivers=swrast \
        "
    elif [ "$osmesadriver" = 3 ]; then
        # gallium osmesa (llvmpipe) OpenGL 3.0, GLSL 1.30
        confopts="${confopts} \
             --disable-osmesa \
             --enable-gallium-osmesa \
             --enable-gallium-llvm=yes \
             --with-llvm-prefix=$llvmprefix \
             --disable-llvm-shared-libs \
             --with-gallium-drivers=swrast \
        "
    else
        # gallium osmesa (swr) OpenGL 3.0, GLSL 1.30
        confopts="${confopts} \
             --disable-osmesa \
             --enable-gallium-osmesa \
             --with-llvm-prefix=$llvmprefix \
             --disable-llvm-shared-libs \
             --with-gallium-drivers=swrast,swr \
        "
    fi

    if [ "$debug" = 1 ]; then
        confopts="${confopts} \
              --enable-debug"
    fi

    if [ "$mangled" = 1 ]; then
        confopts="${confopts} \
           --enable-mangling"
        #sed -i.bak -e 's/"gl"/"mgl"/' src/mapi/glapi/gen/remap_helper.py
        #rm src/mesa/main/remap_helper.h
    fi

    if [ "$osname" = Darwin ]; then
    	osxflags=""
    	# if env var not set/using default setting
    	if [ ! -n "${MACOSX_DEPLOYMENT_TARGET+x}" ]; then
        	# Redundant - provided for older compilers that do not pass this option to the linker
        	env MACOSX_DEPLOYMENT_TARGET=$osxsdkminver
        fi
 		if [ "$osver" -ge 12 ]; then
            # From Mountain Lion onward so we are only building 64bit arch.
            osxflags="$osxflags -arch x86_64"
        fi 
        # Set minimum MacOSX deployment target        
        osxflags="$osxflags -mmacosx-version-min=$osxsdkminver"   
        # Set SDK sys root 
		if [ "$osxsdkisysroot" = 0 ] && [ -x "/usr/bin/xcrun" ]; then
			# if not user specified, automatically set the default OSX SDK root
		    osxflags="$osxflags -isysroot `/usr/bin/xcrun --show-sdk-path -sdk macosx`"            
		fi	                      
        
	    CFLAGS="$CFLAGS $osxflags"
        CXXFLAGS="$CXXFLAGS $osxflags"
    fi
  
    echo "** Mesa autoconf command line arguments..."
    echo "** env"
    echo "** PKG_CONFIG_PATH="
    echo "** CC=\"$CC\""
    echo "** CXX=\"$CXX\""
    echo "** PTHREADSTUBS_CFLAGS=\" \""
    echo "** PTHREADSTUBS_LIBS=\" \""
    echo "** ./configure"
    echo "** ${confopts}"
    echo "** CC=\"$CC\""
    echo "** CFLAGS=\"$CFLAGS\""
    echo "** CXX=\"$CXX\""
    echo "** CXXFLAGS=\"$CXXFLAGS\""
    env PKG_CONFIG_PATH= CC="$CC" CXX="$CXX" PTHREADSTUBS_CFLAGS=" " PTHREADSTUBS_LIBS=" " 
    ./configure ${confopts} CC="$CC" CFLAGS="$CFLAGS" CXX="$CXX" CXXFLAGS="$CXXFLAGS"

    make -j${mkjobs}

    echo "* installing Mesa..."
    make install
	
    if [ "$osname" = Darwin ]; then
        # fix the following error:
        #Undefined symbols for architecture x86_64:
        #  "_lp_dummy_tile", referenced from:
        #      _lp_rast_create in libMangledOSMesa32.a(lp_rast.o)
        #      _lp_setup_set_fragment_sampler_views in libMangledOSMesa32.a(lp_setup.o)
        #ld: symbol(s) not found for architecture x86_64
        #clang: error: linker command failed with exit code 1 (use -v to see invocation)
        for f in $osmesaprefix/lib/lib*.a; do
            ranlib -c $f
        done
    fi

    # End of configure-based build
    ####################################################################
fi

# elapsed mesa build time
if [ "$buildllvm" = 1 ]; then
    SECONDS_MESA=$(($SECONDS - $ELAPSED_LLVM))
    ELAPSED_MESA="Elapsed: $(($SECONDS_MESA / 3600))hrs $((($SECONDS_MESA / 60) % 60))min $(($SECONDS_MESA % 60))sec"
    echo "* Library mesa-${mesaversion} build and install completed. Time $ELAPSED_MESA"
else 
    ELAPSED_MESA="Elapsed: $(($SECONDS / 3600))hrs $((($SECONDS / 60) % 60))min $(($SECONDS % 60))sec"
    echo "* Library mesa-${mesaversion} build and install completed. Time $ELAPSED_MESA"
fi

cd ..

if [ ! -f glu-${gluversion}.tar.bz2 ]; then
    echo "* downloading GLU ${gluversion}..."
    curl $curlopts -O "ftp://ftp.freedesktop.org/pub/mesa/glu/glu-${gluversion}.tar.bz2"
fi
echo "* extracting GLU..."
tar jxf glu-${gluversion}.tar.bz2
cd glu-${gluversion}
echo "* building GLU..."
confopts="\
    --disable-dependency-tracking \
    --enable-static \
    --disable-shared \
    --enable-osmesa \
    --prefix=$osmesaprefix"
if [ "$mangled" = 1 ]; then
    confopts="${confopts} \
     CPPFLAGS=-DUSE_MGL_NAMESPACE"
fi

echo "** GLU autoconf command line arguments..."
echo "** env"
echo "** PKG_CONFIG_PATH=\"$osmesaprefix\"/lib/pkgconfig"
echo "** ./configure"
echo "** ${confopts}"
echo "** CFLAGS=\"$CFLAGS\""
echo "** CXXFLAGS=\"$CXXFLAGS\""
env PKG_CONFIG_PATH="$osmesaprefix"/lib/pkgconfig 
./configure ${confopts} CFLAGS="$CFLAGS" CXXFLAGS="$CXXFLAGS"
make -j${mkjobs}
echo "* installing GLU..."
make install

if [ "$mangled" = 1 ]; then
    mv "$osmesaprefix/lib/libGLU.a" "$osmesaprefix/lib/libMangledGLU.a"
    mv "$osmesaprefix/lib/libGLU.la" "$osmesaprefix/lib/libMangledGLU.la"
    sed -e s/libGLU/libMangledGLU/g -i.bak "$osmesaprefix/lib/libMangledGLU.la"
    sed -e s/-lGLU/-lMangledGLU/g -i.bak "$osmesaprefix/lib/pkgconfig/glu.pc"
fi

# elapsed glu execution time
SECONDS_GLU=$(($SECONDS - $ELAPSED_MESA))
ELAPSED_GLU="Elapsed: $(($SECONDS_GLU / 3600))hrs $((($SECONDS_GLU / 60) % 60))min $(($SECONDS_GLU % 60))sec"
echo "* Library glu-${gluversion} build and install completed. Time $ELAPSED_GLU"

if [ "$ignoredemo" = 0]; then

    # build the demo
    
    cd ..
    if [ ! -f mesa-demos-${demoversion}.tar.bz2 ]; then
        echo "* downloading Mesa Demos ${demoversion}..."
        curl $curlopts -O "ftp://ftp.freedesktop.org/pub/mesa/demos/${demoversion}/mesa-demos-${demoversion}.tar.bz2"
    fi
    echo "* extracting Mesa demo..."
    tar jxf mesa-demos-${demoversion}.tar.bz2

    cd mesa-demos-${demoversion}/src/osdemos
    echo "* building Mesa demo..."
    # We need to include gl_mangle.h and glu_mangle.h, because osdemo32.c doesn't include them

    INCLUDES="-include $osmesaprefix/include/GL/gl.h -include $osmesaprefix/include/GL/glu.h"
    if [ "$mangled" = 1 ]; then
        INCLUDES="-include $osmesaprefix/include/GL/gl_mangle.h -include $osmesaprefix/include/GL/glu_mangle.h $INCLUDES"
        LIBS32="-lMangledOSMesa32 -lMangledGLU"
    else
        LIBS32="-lOSMesa32 -lGLU"
    fi
    if [ -z "${OSDEMO_LD:-}" ]; then
        OSDEMO_LD="$CXX"
    fi
    if [ "$osname" = Darwin ]; then
    	# add -stdlib=libc++ to correct llvm generated Undefined sysbols std::__1::<symbol> for architecture link errors.
    	OSDEMO_LD="$OSDEMO_LD -stdlib=libc++"
    fi
    # strange, got 'Undefined symbols for architecture x86_64' on MacOSX and without zlib for both llvmpipe and softpipe drivers.
    # also got 'undefined reference' to [the same missing symbols] on Linux - so I moved -lz here from the Darwin condition.
    # missing symbols are _deflate, _deflateEnd, _deflateInit_, _inflate, _inflateEnd and _inflateInit
    LIBS32="$LIBS32 -lz"

    echo "$OSDEMO_LD $CFLAGS -I$osmesaprefix/include -I../../src/util $INCLUDES  -o osdemo32 osdemo32.c -L$osmesaprefix/lib $LIBS32 $llvmlibs"
    $OSDEMO_LD $CFLAGS -I$osmesaprefix/include -I../../src/util $INCLUDES  -o osdemo32 osdemo32.c -L$osmesaprefix/lib $LIBS32 $llvmlibs
    # image test result is file image.tga
    ./osdemo32 image.tga

    # elapsed demo execution time
    SECONDS_DEMO=$(($SECONDS - $ELAPSED_GLU))
    ELAPSED_DEMO="Elapsed: $(($SECONDS_DEMO / 3600))hrs $((($SECONDS_DEMO / 60) % 60))min $(($SECONDS_DEMO % 60))sec"
    echo "* Demo mesa-demos-${demoversion} build and execution completed. Time $ELAPSED_DEMO"
fi
# elapsed scrpt execution time
ELAPSED="Elapsed: $(($SECONDS / 3600))hrs $((($SECONDS / 60) % 60))min $(($SECONDS % 60))sec"
echo "* Done!. $scriptname ran to completion. Time $ELAPSED"
exit

# Useful information:
#
# To avoid costly delays, be sure zlib is installed
# for example on Ubuntu: sudo apt-get install zlib1g-dev
# Configuring osmesa 9.2.2:
# http://www.paraview.org/Wiki/ParaView/ParaView_And_Mesa_3D#OSMesa.2C_Mesa_without_graphics_hardware

# MESA_GL_VERSION_OVERRIDE an OSMesa should not be used before Mesa 11.2,
# + patch for earlier versions:
# https://cmake.org/pipermail/paraview/2015-December/035804.html
# patch: http://public.kitware.com/pipermail/paraview/attachments/20151217/4854b0ad/attachment.bin

# llvmpipe vs swrast benchmarks:
# https://cmake.org/pipermail/paraview/2015-December/035807.html

#env MESA_GL_VERSION_OVERRIDE=3.2 MESA_GLSL_VERSION_OVERRIDE=150 ./osdemo32

# Local Variables:
# indent-tabs-mode: nil
# sh-basic-offset: 4
# sh-indentation: 4
