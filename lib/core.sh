#!/usr/bin/env bash
#
# Copyright (c) 2012-2015
#
# This program is free software; you can redistribute it and/or modify it
# under the terms of the GNU Library General Public License as published
# by the Free Software Foundation; either version 2, or (at your option)
# any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

# References:
# https://wiki.archlinux.org/index.php/PKGBUILD
# https://wiki.archlinux.org/index.php/Creating_Packages

set -e

################################ IMPORTS #################################
source "$(dirname ${BASH_ARGV[0]})/util.sh"

################################# VARIABLES ##############################

NAME='JuNest'
CMD='junest'
VERSION='4.7.4'
CODE_NAME='Mairei'
DESCRIPTION='The Arch Linux based distro that runs upon any Linux distros without root access'
AUTHOR='Filippo Squillace <feel dot squally at gmail.com>'
HOMEPAGE="https://github.com/fsquillace/${CMD}"
COPYRIGHT='2012-2015'


if [ "$JUNEST_ENV" == "1" ]
then
    die "Error: Nested ${NAME} environments are not allowed"
elif [ ! -z $JUNEST_ENV ] && [ "$JUNEST_ENV" != "0" ]
then
    die "The variable JUNEST_ENV is not properly set"
fi

[ -z ${JUNEST_HOME} ] && JUNEST_HOME=~/.${CMD}
if [ -z ${JUNEST_TEMPDIR} ] || [ ! -d ${JUNEST_TEMPDIR} ]
then
    JUNEST_TEMPDIR=/tmp
fi

ENV_REPO=https://dl.dropboxusercontent.com/u/42449030/${CMD}
ORIGIN_WD=$(pwd)

WGET="wget --no-check-certificate"
CURL="curl -L -J -O -k"

TAR=tar

DEFAULT_MIRROR='https://mirrors.kernel.org/archlinux/$repo/os/$arch'

HOST_ARCH=$(uname -m)

if [ $HOST_ARCH == "i686" ] || [ $HOST_ARCH == "i386" ]
then
    ARCH="x86"
    LD_LIB="${JUNEST_HOME}/lib/ld-linux.so.2"
elif [ $HOST_ARCH == "x86_64" ]
then
    ARCH="x86_64"
    LD_LIB="${JUNEST_HOME}/lib64/ld-linux-x86-64.so.2"
elif [[ $HOST_ARCH =~ .*(arm).* ]]
then
    ARCH="arm"
    LD_LIB="${JUNEST_HOME}/lib/ld-linux-armhf.so.3"
else
    die "Unknown architecture ${ARCH}"
fi

PROOT_COMPAT="${JUNEST_HOME}/opt/proot/proot-${ARCH}"
PROOT_LINK=http://static.proot.me/proot-${ARCH}

SH=("/bin/sh" "--login")
CHROOT=${JUNEST_HOME}/usr/bin/arch-chroot
CLASSIC_CHROOT=${JUNEST_HOME}/usr/bin/chroot
TRUE=/usr/bin/true
ID="/usr/bin/id -u"
CHOWN="${JUNEST_HOME}/usr/bin/chown"
LN="ln"

################################# MAIN FUNCTIONS ##############################

function download(){
    $WGET $1 || $CURL $1 || \
        die "Error: Both wget and curl commands have failed on downloading $1"
}

function is_env_installed(){
    [ -d "$JUNEST_HOME" ] && [ "$(ls -A $JUNEST_HOME)" ] && return 0
    return 1
}


function _cleanup_build_directory(){
# $1: maindir (optional) - str: build directory to get rid
    local maindir=$1
    builtin cd $ORIGIN_WD
    trap - QUIT EXIT ABRT KILL TERM INT
    rm -fr "$maindir"
}


function _prepare_build_directory(){
    trap - QUIT EXIT ABRT KILL TERM INT
    trap "rm -rf ${maindir}; die \"Error occurred when installing ${NAME}\"" EXIT QUIT ABRT KILL TERM INT
}


function _setup_env(){
    is_env_installed && die "Error: ${NAME} has been already installed in $JUNEST_HOME"
    mkdir -p "${JUNEST_HOME}"
    imagepath=$1
    $TAR -zxpf ${imagepath} -C ${JUNEST_HOME}
    mkdir -p ${JUNEST_HOME}/run/lock
    info "The default mirror URL is ${DEFAULT_MIRROR}."
    info "Remember to refresh the package databases from the server:"
    info "    pacman -Syy"
    info "${NAME} installed successfully"
}


function setup_env(){
    local maindir=$(TMPDIR=$JUNEST_TEMPDIR mktemp -d -t ${CMD}.XXXXXXXXXX)
    _prepare_build_directory

    info "Downloading ${NAME}..."
    builtin cd ${maindir}
    local imagefile=${CMD}-${ARCH}.tar.gz
    download ${ENV_REPO}/${imagefile}

    info "Installing ${NAME}..."
    _setup_env ${maindir}/${imagefile}

    _cleanup_build_directory ${maindir}
}


function setup_env_from_file(){
    local imagefile=$1
    [ ! -e ${imagefile} ] && die "Error: The ${NAME} image file ${imagefile} does not exist"

    info "Installing ${NAME} from ${imagefile}..."
    _setup_env ${imagefile}

    builtin cd $ORIGIN_WD
}


function run_env_as_root(){
    local uid=$UID
    [ -z $SUDO_UID ] || uid=$SUDO_UID:$SUDO_GID

    local main_cmd="${SH[@]}"
    [ "$1" != "" ] && main_cmd="$(insert_quotes_on_spaces "$@")"
    local cmd="mkdir -p ${JUNEST_HOME}/${HOME} && mkdir -p /run/lock && ${main_cmd}"

    trap - QUIT EXIT ABRT KILL TERM INT
    trap "[ -z $uid ] || ${CHOWN} -R ${uid} ${JUNEST_HOME}; rm -r ${JUNEST_HOME}/etc/mtab" EXIT QUIT ABRT KILL TERM INT

    [ ! -e ${JUNEST_HOME}/etc/mtab ] && $LN -s /proc/self/mounts ${JUNEST_HOME}/etc/mtab

    if ${CHROOT} $JUNEST_HOME ${TRUE} 1> /dev/null
    then
        JUNEST_ENV=1 ${CHROOT} $JUNEST_HOME "${SH[@]}" "-c" "${cmd}"
        local ret=$?
    elif ${CLASSIC_CHROOT} $JUNEST_HOME ${TRUE} 1> /dev/null
    then
        warn "Warning: The executable arch-chroot does not work, falling back to classic chroot"
        JUNEST_ENV=1 ${CLASSIC_CHROOT} $JUNEST_HOME "${SH[@]}" "-c" "${cmd}"
        local ret=$?
    else
        die "Error: Chroot does not work"
    fi

    # The ownership of the files is assigned to the real user
    [ -z $uid ] || ${CHOWN} -R ${uid} ${JUNEST_HOME}

    [ -e ${JUNEST_HOME}/etc/mtab ] && rm -r ${JUNEST_HOME}/etc/mtab

    trap - QUIT EXIT ABRT KILL TERM INT
    return $?
}

function _run_proot(){
    local proot_args="$1"
    shift
    if ${PROOT_COMPAT} $proot_args ${TRUE} 1> /dev/null
    then
        JUNEST_ENV=1 ${PROOT_COMPAT} $proot_args "${@}"
    elif PROOT_NO_SECCOMP=1 ${PROOT_COMPAT} $proot_args ${TRUE} 1> /dev/null
    then
        warn "Proot error: Trying to execute proot with PROOT_NO_SECCOMP=1..."
        JUNEST_ENV=1 PROOT_NO_SECCOMP=1 ${PROOT_COMPAT} $proot_args "${@}"
    else
        die "Error: Check if the ${CMD} arguments are correct or use the option ${CMD} -p \"-k 3.10\""
    fi
}


function _run_env_with_proot(){
    local proot_args="$1"
    shift

    if [ "$1" != "" ]
    then
       _run_proot "${proot_args}" "${SH[@]}" "-c" "$(insert_quotes_on_spaces "${@}")"
    else
        _run_proot "${proot_args}" "${SH[@]}"
    fi
}


function run_env_as_fakeroot(){
    local proot_args="$1"
    shift
    [ "$(_run_proot "-R ${JUNEST_HOME} $proot_args" ${ID} 2> /dev/null )" == "0" ] && \
        die "You cannot access with root privileges. Use --root option instead."

    [ ! -e ${JUNEST_HOME}/etc/mtab ] && $LN -s /proc/self/mounts ${JUNEST_HOME}/etc/mtab
    _run_env_with_proot "-S ${JUNEST_HOME} $proot_args" "${@}"
}


function run_env_as_user(){
    local proot_args="$1"
    shift
    [ "$(_run_proot "-R ${JUNEST_HOME} $proot_args" ${ID} 2> /dev/null )" == "0" ] && \
        die "You cannot access with root privileges. Use --root option instead."

    [ -e ${JUNEST_HOME}/etc/mtab ] && rm -f ${JUNEST_HOME}/etc/mtab
    _run_env_with_proot "-R ${JUNEST_HOME} $proot_args" "${@}"
}


function delete_env(){
    ! ask "Are you sure to delete ${NAME} located in ${JUNEST_HOME}" "N" && return
    if mountpoint -q ${JUNEST_HOME}
    then
        info "There are mounted directories inside ${JUNEST_HOME}"
        if ! umount --force ${JUNEST_HOME}
        then
            error "Cannot umount directories in ${JUNEST_HOME}"
            die "Try to delete ${NAME} using root permissions"
        fi
    fi
    # the CA directories are read only and can be deleted only by changing the mod
    chmod -R +w ${JUNEST_HOME}/etc/ca-certificates
    if rm -rf ${JUNEST_HOME}/*
    then
        info "${NAME} deleted in ${JUNEST_HOME}"
    else
        error "Error: Cannot delete ${NAME} in ${JUNEST_HOME}"
    fi
}


function _check_package(){
    if ! pacman -Qq $1 > /dev/null
    then
        die "Package $1 must be installed"
    fi
}


function build_image_env(){
# The function must runs on ArchLinux with non-root privileges.
    [ "$(${ID})" == "0" ] && \
        die "You cannot build with root privileges."

    _check_package arch-install-scripts
    _check_package gcc
    _check_package package-query
    _check_package git

    local disable_validation=$1

    local maindir=$(TMPDIR=$JUNEST_TEMPDIR mktemp -d -t ${CMD}.XXXXXXXXXX)
    sudo mkdir -p ${maindir}/root
    trap - QUIT EXIT ABRT KILL TERM INT
    trap "sudo rm -rf ${maindir}; die \"Error occurred when installing ${NAME}\"" EXIT QUIT ABRT KILL TERM INT
    info "Installing pacman and its dependencies..."
    # The archlinux-keyring and libunistring are due to missing dependencies declaration in ARM archlinux
    # yaourt requires sed
    # coreutils is needed for chown
    sudo pacstrap -G -M -d ${maindir}/root pacman arch-install-scripts coreutils binutils libunistring archlinux-keyring sed
    sudo bash -c "echo 'Server = $DEFAULT_MIRROR' >> ${maindir}/root/etc/pacman.d/mirrorlist"

    info "Generating the locales..."
    # sed command is required for locale-gen
    sudo ln -sf /usr/share/zoneinfo/posix/UTC ${maindir}/root/etc/localtime
    sudo bash -c "echo 'en_US.UTF-8 UTF-8' >> ${maindir}/root/etc/locale.gen"
    sudo arch-chroot ${maindir}/root locale-gen
    sudo bash -c "echo 'LANG = \"en_US.UTF-8\"' >> ${maindir}/root/etc/locale.conf"

    info "Installing compatibility binary proot"
    sudo mkdir -p ${maindir}/root/opt/proot
    builtin cd ${maindir}/root/opt/proot
    sudo $CURL $PROOT_LINK
    sudo chmod +x proot-$ARCH

    # AUR packages requires non-root user to be compiled. proot fakes the user to 10
    info "Compiling and installing yaourt..."
    mkdir -p ${maindir}/packages/{package-query,yaourt}

    builtin cd ${maindir}/packages/package-query
    download https://aur.archlinux.org/packages/pa/package-query/PKGBUILD
    makepkg -sfc
    sudo pacman --noconfirm --root ${maindir}/root -U package-query*.pkg.tar.xz

    builtin cd ${maindir}/packages/yaourt
    download https://aur.archlinux.org/packages/ya/yaourt/PKGBUILD
    makepkg -sfc
    sudo pacman --noconfirm --root ${maindir}/root -U yaourt*.pkg.tar.xz
    # Apply patches for yaourt and makepkg
    sudo mkdir -p ${maindir}/root/opt/yaourt/bin/
    sudo cp ${maindir}/root/usr/bin/yaourt ${maindir}/root/opt/yaourt/bin/
    sudo sed -i -e 's/"--asroot"//' ${maindir}/root/opt/yaourt/bin/yaourt
    sudo cp ${maindir}/root/usr/bin/makepkg ${maindir}/root/opt/yaourt/bin/
    sudo sed -i -e 's/EUID\s==\s0/false/' ${maindir}/root/opt/yaourt/bin/makepkg
    sudo bash -c "echo 'export PATH=/opt/yaourt/bin:$PATH' > ${maindir}/root/etc/profile.d/${CMD}.sh"
    sudo chmod +x ${maindir}/root/etc/profile.d/${CMD}.sh

    info "Copying ${NAME} scripts..."
    sudo git clone https://github.com/fsquillace/${CMD}.git ${maindir}/root/opt/${CMD}

    info "Setting up the pacman keyring (this might take a while!)..."
    sudo arch-chroot ${maindir}/root bash -c "pacman-key --init; pacman-key --populate archlinux"

    sudo rm ${maindir}/root/var/cache/pacman/pkg/*

    mkdir -p ${maindir}/output
    builtin cd ${maindir}/output
    local imagefile="${CMD}-${ARCH}.tar.gz"
    info "Compressing image to ${imagefile}..."
    sudo $TAR -zcpf ${imagefile} -C ${maindir}/root .

    mkdir -p ${maindir}/root_test
    $disable_validation || validate_image "${maindir}/root_test" "${imagefile}"

    sudo cp ${maindir}/output/${imagefile} ${ORIGIN_WD}

    builtin cd ${ORIGIN_WD}
    trap - QUIT EXIT ABRT KILL TERM INT
    sudo rm -fr "$maindir"
}

function validate_image(){
    local testdir=$1
    local imagefile=$2
    info "Validating ${NAME} image..."
    $TAR -zxpf ${imagefile} -C ${testdir}
    mkdir -p ${testdir}/run/lock
    sed -i -e "s/#Server/Server/" ${testdir}/etc/pacman.d/mirrorlist
    JUNEST_HOME=${testdir} ${testdir}/opt/${CMD}/bin/${CMD} -f pacman --noconfirm -Syy

    # Check most basic executables work
    JUNEST_HOME=${testdir} sudo -E ${testdir}/opt/${CMD}/bin/${CMD} -r pacman -Qi pacman 1> /dev/null
    JUNEST_HOME=${testdir} sudo -E ${testdir}/opt/${CMD}/bin/${CMD} -r yaourt -V 1> /dev/null
    JUNEST_HOME=${testdir} sudo -E ${testdir}/opt/${CMD}/bin/${CMD} -r /opt/proot/proot-$ARCH --help 1> /dev/null
    JUNEST_HOME=${testdir} sudo -E ${testdir}/opt/${CMD}/bin/${CMD} -r arch-chroot --help 1> /dev/null

    local repo_package=sysstat
    info "Installing ${repo_package} package from official repo using proot..."
    JUNEST_HOME=${testdir} ${testdir}/opt/${CMD}/bin/${CMD} -f pacman --noconfirm -S ${repo_package}
    JUNEST_HOME=${testdir} ${testdir}/opt/${CMD}/bin/${CMD} iostat
    JUNEST_HOME=${testdir} ${testdir}/opt/${CMD}/bin/${CMD} -f iostat

    local repo_package=iftop
    info "Installing ${repo_package} package from official repo using root..."
    JUNEST_HOME=${testdir} ${testdir}/opt/${CMD}/bin/${CMD} -f pacman --noconfirm -S ${repo_package}
    JUNEST_HOME=${testdir} sudo -E ${testdir}/opt/${CMD}/bin/${CMD} -r iftop -t -s 5

    JUNEST_HOME=${testdir} ${testdir}/opt/${CMD}/bin/${CMD} -f pacman --noconfirm -S base-devel
    local yaourt_package=tcptraceroute
    info "Installing ${yaourt_package} package from AUR repo using proot..."
    JUNEST_HOME=${testdir} ${testdir}/opt/${CMD}/bin/${CMD} -f sh --login -c "yaourt -A --noconfirm -S ${yaourt_package}"
    JUNEST_HOME=${testdir} sudo -E ${testdir}/opt/${CMD}/bin/${CMD} -r tcptraceroute localhost

}
