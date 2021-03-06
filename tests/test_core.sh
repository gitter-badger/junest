#!/bin/bash

function oneTimeSetUp(){
    [ -z "$SKIP_ROOT_TESTS" ] && SKIP_ROOT_TESTS=0

    CURRPWD=$PWD
    ENV_MAIN_HOME=/tmp/envtesthome
    [ -e $ENV_MAIN_HOME ] || JUNEST_HOME=$ENV_MAIN_HOME bash --rcfile "$(dirname $0)/../lib/core.sh" -ic "setup_env"
    JUNEST_HOME=""
}

function install_mini_env(){
    cp -rfa $ENV_MAIN_HOME/* $JUNEST_HOME
}

function setUp(){
    cd $CURRPWD
    JUNEST_HOME=$(TMPDIR=/tmp mktemp -d -t envhome.XXXXXXXXXX)
    source "$(dirname $0)/../lib/core.sh"
    ORIGIN_WD=$(TMPDIR=/tmp mktemp -d -t envowd.XXXXXXXXXX)
    cd $ORIGIN_WD
    JUNEST_TEMPDIR=$(TMPDIR=/tmp mktemp -d -t envtemp.XXXXXXXXXX)

    set +e

    trap - QUIT EXIT ABRT KILL TERM INT
    trap "rm -rf ${JUNEST_HOME}; rm -rf ${ORIGIN_WD}; rm -rf ${JUNEST_TEMPDIR}" EXIT QUIT ABRT KILL TERM INT
}


function tearDown(){
    # the CA directories are read only and can be deleted only by changing the mod
    [ -d ${JUNEST_HOME}/etc/ca-certificates ] && chmod -R +w ${JUNEST_HOME}/etc/ca-certificates
    rm -rf $JUNEST_HOME
    rm -rf $ORIGIN_WD
    rm -rf $JUNEST_TEMPDIR
    trap - QUIT EXIT ABRT KILL TERM INT
}


function test_is_env_installed(){
    is_env_installed
    assertEquals $? 1
    touch $JUNEST_HOME/just_file
    is_env_installed
    assertEquals $? 0
}


function test_download(){
    WGET=/bin/true
    CURL=/bin/false
    download
    assertEquals $? 0

    WGET=/bin/false
    CURL=/bin/true
    download
    assertEquals $? 0

    $(WGET=/bin/false CURL=/bin/false download something 2> /dev/null)
    assertEquals $? 1
}


function test_setup_env(){
    wget_mock(){
        # Proof that the setup is happening
        # inside $JUNEST_TEMPDIR
        local cwd=${PWD#${JUNEST_TEMPDIR}}
        local parent_dir=${PWD%${cwd}}
        assertEquals "$JUNEST_TEMPDIR" "${parent_dir}"
        touch file
        tar -czvf ${CMD}-${ARCH}.tar.gz file
    }
    WGET=wget_mock
    setup_env 1> /dev/null
    assertTrue "[ -e $JUNEST_HOME/file ]"
    assertTrue "[ -e $JUNEST_HOME/run/lock ]"
}


function test_setup_env_from_file(){
    touch file
    tar -czvf ${CMD}-${ARCH}.tar.gz file 1> /dev/null
    setup_env_from_file ${CMD}-${ARCH}.tar.gz &> /dev/null
    assertTrue "[ -e $JUNEST_HOME/file ]"
    assertTrue "[ -e $JUNEST_HOME/run/lock ]"

    $(setup_env_from_file noexist.tar.gz 2> /dev/null)
    assertEquals $? 1
}

function test_setup_env_from_file_with_absolute_path(){
    touch file
    tar -czvf ${CMD}-${ARCH}.tar.gz file 1> /dev/null
    setup_env_from_file ${ORIGIN_WD}/${CMD}-${ARCH}.tar.gz &> /dev/null
    assertTrue "[ -e $JUNEST_HOME/file ]"
    assertTrue "[ -e $JUNEST_HOME/run/lock ]"
}

function test_run_env_as_root(){
    [ $SKIP_ROOT_TESTS -eq 1 ] && return

    install_mini_env
    CHROOT="sudo $CHROOT"
    CLASSIC_CHROOT="sudo $CLASSIC_CHROOT"
    CHOWN="sudo $CHOWN"

    local output=$(run_env_as_root pwd)
    assertEquals "/" "$output"
    run_env_as_root [ -e /run/lock ]
    assertEquals 0 $?
    run_env_as_root [ -e $HOME ]
    assertEquals 0 $?

    # test that normal user has ownership of the files created by root
    run_env_as_root touch /a_root_file
    local output=$(run_env_as_root stat -c '%u' /a_root_file)
    assertEquals "$UID" "$output"

    SH=("sh" "--login" "-c" "type -t type")
    local output=$(run_env_as_root)
    assertEquals "builtin" "$output"
    SH=("sh" "--login" "-c" "[ -e /run/lock ]")
    run_env_as_root
    assertEquals 0 $?
    SH=("sh" "--login" "-c" "[ -e $HOME ]")
    run_env_as_root
    assertEquals 0 $?
}

function test_run_env_as_classic_root(){
    [ $SKIP_ROOT_TESTS -eq 1 ] && return

    install_mini_env
    CHROOT="sudo unknowncommand"
    CLASSIC_CHROOT="sudo $CLASSIC_CHROOT"
    CHOWN="sudo $CHOWN"

    local output=$(run_env_as_root pwd 2> /dev/null)
    assertEquals "/" "$output"
    run_env_as_root [ -e /run/lock ] 2> /dev/null
    assertEquals 0 $?
    run_env_as_root [ -e $HOME ] 2> /dev/null
    assertEquals 0 $?
}

function test_run_env_as_user(){
    install_mini_env
    local output=$(run_env_as_user "-k 3.10" "/usr/bin/mkdir" "-v" "/newdir2" | awk -F: '{print $1}')
    assertEquals "$output" "/usr/bin/mkdir"
    assertTrue "[ -e $JUNEST_HOME/newdir2 ]"

    SH=("/usr/bin/mkdir" "-v" "/newdir")
    local output=$(run_env_as_user "-k 3.10" | awk -F: '{print $1}')
    assertEquals "$output" "/usr/bin/mkdir"
    assertTrue "[ -e $JUNEST_HOME/newdir ]"
}

function test_run_env_as_proot_mtab(){
    install_mini_env
    $(run_env_as_fakeroot "-k 3.10" "echo")
    assertTrue "[ -e $JUNEST_HOME/etc/mtab ]"
    $(run_env_as_user "-k 3.10" "echo")
    assertTrue "[ ! -e $JUNEST_HOME/etc/mtab ]"
}

function test_run_env_as_root_mtab(){
    [ $SKIP_ROOT_TESTS -eq 1 ] && return

    install_mini_env
    CHROOT="sudo $CHROOT"
    CLASSIC_CHROOT="sudo $CLASSIC_CHROOT"
    CHOWN="sudo $CHOWN"
    $(run_env_as_root "echo")
    assertTrue "[ ! -e $JUNEST_HOME/etc/mtab ]"
}

function test_run_env_with_quotes(){
    install_mini_env
    local output=$(run_env_as_user "-k 3.10" "bash" "-c" "/usr/bin/mkdir -v /newdir2" | awk -F: '{print $1}')
    assertEquals "$output" "/usr/bin/mkdir"
    assertTrue "[ -e $JUNEST_HOME/newdir2 ]"
}

function test_run_env_as_user_proot_args(){
    install_mini_env
    run_env_as_user "--help" "" &> /dev/null
    assertEquals $? 0

    mkdir $JUNEST_TEMPDIR/newdir
    touch $JUNEST_TEMPDIR/newdir/newfile
    run_env_as_user "-b $JUNEST_TEMPDIR/newdir:/newdir -k 3.10" "ls" "-l" "/newdir/newfile" &> /dev/null
    assertEquals $? 0

    $(_run_env_with_proot --helps 2> /dev/null)
    assertEquals $? 1
}

function test_run_env_with_proot_compat(){
    PROOT_COMPAT="/bin/true"
    _run_env_with_proot "" "" &> /dev/null
    assertEquals $? 0

    $(PROOT_COMPAT="/bin/false" _run_env_with_proot --helps 2> /dev/null)
    assertEquals $? 1
}

function test_run_env_with_proot_as_root(){
    install_mini_env

    $(ID="/bin/echo 0" run_env_as_user 2> /dev/null)
    assertEquals $? 1
    $(ID="/bin/echo 0" run_env_as_fakeroot 2> /dev/null)
    assertEquals $? 1
}

function test_run_proot_seccomp(){
    TRUE=""
    PROOT_COMPAT=env
    local output=$(_run_proot | grep "^PROOT_NO_SECCOMP")
    assertEquals "$output" ""

    envv(){
        env | grep "^PROOT_NO_SECCOMP"
    }
    PROOT_COMPAT=envv
    local output=$(_run_proot 2> /dev/null | grep "^PROOT_NO_SECCOMP")
    assertEquals "$output" "PROOT_NO_SECCOMP=1"
}

function test_run_env_as_fakeroot(){
    install_mini_env
    local output=$(run_env_as_fakeroot "-k 3.10" "id" | awk '{print $1}')
    assertEquals "$output" "uid=0(root)"
}

function test_delete_env(){
    install_mini_env
    echo "N" | delete_env 1> /dev/null
    is_env_installed
    assertEquals $? 0
    echo "Y" | delete_env 1> /dev/null
    is_env_installed
    assertEquals $? 1
}

function test_nested_env(){
    install_mini_env
    JUNEST_ENV=1 bash -ic "source $CURRPWD/$(dirname $0)/../lib/core.sh" &> /dev/null
    assertEquals $? 1
}

source $(dirname $0)/shunit2
