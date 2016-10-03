#!/bin/bash
set -e
set -x

NUM_CPUS=`nproc`
echo "###############"
echo "### Using ${NUM_CPUS} cores"

# setup some build variables
BUILD_USER=vagrant
BUILD_GROUP=vagrant
BUILD_ROOT=/var/kernel_build
BUILD_CACHE=$BUILD_ROOT/cache
ARM_TOOLS=$BUILD_CACHE/tools
LINUX_KERNEL=$BUILD_CACHE/linux-kernel
# LINUX_KERNEL_COMMIT=4eda74f2dfcc8875482575c79471bde6766de3ad # Linux 4.4.15
# LINUX_KERNEL_COMMIT=52261e73a34f9ed7f1d049902842895a2c433a50 # Linux 4.4.10
# LINUX_KERNEL_COMMIT=36311a9ec4904c080bbdfcefc0f3d609ed508224 # Linux 4.1.8
# LINUX_KERNEL_COMMIT="59e76bb7e2936acd74938bb385f0884e34b91d72"
# LINUX_KERNEL_COMMIT=1f58c41a5aba262958c2869263e6fdcaa0aa3c00
RASPBERRY_FIRMWARE=$BUILD_CACHE/rpi_firmware

if [ -d /vagrant ]; then
  # running in vagrant VM
  SRC_DIR=/vagrant
else
  # running in drone build
  SRC_DIR=`pwd`
  BUILD_USER=`id -u -n`
  BUILD_GROUP=`id -g -n`
fi

LINUX_KERNEL_CONFIGS=$SRC_DIR/kernel_configs

NEW_VERSION=`date +%Y%m%d-%H%M%S`
BUILD_RESULTS=$BUILD_ROOT/results/kernel-$NEW_VERSION

X64_CROSS_COMPILE_CHAIN=arm-bcm2708/gcc-linaro-arm-linux-gnueabihf-raspbian-x64

declare -A CCPREFIX
CCPREFIX["rpi1"]=$ARM_TOOLS/$X64_CROSS_COMPILE_CHAIN/bin/arm-linux-gnueabihf-
CCPREFIX["rpi2_3"]=$ARM_TOOLS/$X64_CROSS_COMPILE_CHAIN/bin/arm-linux-gnueabihf-

declare -A IMAGE_NAME
IMAGE_NAME["rpi1"]=kernel.img
IMAGE_NAME["rpi2_3"]=kernel7.img

function create_dir_for_build_user () {
    local target_dir=$1

    sudo mkdir -p $target_dir
    sudo chown $BUILD_USER:$BUILD_GROUP $target_dir
}

function setup_build_dirs () {
  for dir in $BUILD_ROOT $BUILD_CACHE $BUILD_RESULTS $ARM_TOOLS $LINUX_KERNEL $RASPBERRY_FIRMWARE; do
    create_dir_for_build_user $dir
  done
}

function clone_or_update_repo_for () {
  local repo_url=$1
  local repo_path=$2
  local repo_commit=$3

  if [ ! -z "${repo_commit}" ]; then
    rm -rf $repo_path
  fi
  if [ -d ${repo_path}/.git ]; then
    cd $repo_path
    git reset --hard HEAD
    git pull
  else
    echo "Cloning $repo_path with commit $repo_commit"
    git clone --depth 20 $repo_url $repo_path
    if [ ! -z "${repo_commit}" ]; then
      cd $repo_path && git checkout -qf ${repo_commit}
    fi
  fi
}

function setup_arm_cross_compiler_toolchain () {
  echo "### Check if Raspberry Pi Crosscompiler repository at ${ARM_TOOLS} is still up to date"
  clone_or_update_repo_for 'https://github.com/raspberrypi/tools.git' $ARM_TOOLS ""
}

function setup_linux_kernel_sources () {
  echo "### Check if Raspberry Pi Linux Kernel repository at ${LINUX_KERNEL} is still up to date"
  clone_or_update_repo_for 'https://github.com/raspberrypi/linux.git' $LINUX_KERNEL $LINUX_KERNEL_COMMIT

  pushd $LINUX_KERNEL

  #download aufs source
  rm -rf aufs4-standalone
  git clone 'https://github.com/sfjro/aufs4-standalone'
  cd aufs4-standalone
  git checkout origin/aufs4.4

  cp -a fs ../
  cp include/uapi/linux/aufs_type.h ../include/uapi/linux
  cd ..

  for patch in $(ls aufs4-standalone/*.patch); do
    patch -p1 < $patch
  done

  make mrproper

  popd

  echo "### Cleaning .version file for deb packages"
  rm -f $LINUX_KERNEL/.version
}

function setup_rpi_firmware () {
  echo "### Check if Raspberry Pi Firmware repository at ${LINUX_KERNEL} is still up to date"
  clone_or_update_repo_for 'https://github.com/RPi-Distro/firmware' $RASPBERRY_FIRMWARE ""
}

function prepare_kernel_building () {
  setup_build_dirs
  setup_arm_cross_compiler_toolchain
  setup_linux_kernel_sources
  setup_rpi_firmware
}


create_kernel_for () {
  echo "###############"
  echo "### START building kernel for ${PI_VERSION}"

  local PI_VERSION=$1

  cd $LINUX_KERNEL

  # add kernel branding for HypriotOS
  sed -i 's/^EXTRAVERSION =.*/EXTRAVERSION = -hypriotos/g' Makefile

  # save git commit id of this build
  local KERNEL_COMMIT=`git rev-parse HEAD`
  echo "### git commit id of this kernel build is ${KERNEL_COMMIT}"

  # clean build artifacts
  make ARCH=arm clean

  # copy kernel configuration file over
  cp $LINUX_KERNEL_CONFIGS/${PI_VERSION}_docker_kernel_config $LINUX_KERNEL/.config

  echo "### building kernel"
  mkdir -p $BUILD_RESULTS/$PI_VERSION
  echo $KERNEL_COMMIT > $BUILD_RESULTS/kernel-commit.txt
  if [ ! -z "${MENUCONFIG}" ]; then
    echo "### starting menuconfig"
    ARCH=arm CROSS_COMPILE=${CCPREFIX[$PI_VERSION]} make menuconfig
    echo "### saving new config back to $LINUX_KERNEL_CONFIGS/${PI_VERSION}_docker_kernel_config"
    cp $LINUX_KERNEL/.config $LINUX_KERNEL_CONFIGS/${PI_VERSION}_docker_kernel_config
    return
  fi

  echo "### building kernel and deb packages"
  KBUILD_DEBARCH=armhf ARCH=arm CROSS_COMPILE=${CCPREFIX[${PI_VERSION}]} make deb-pkg -j$NUM_CPUS

  ${LINUX_KERNEL}/scripts/mkknlimg $LINUX_KERNEL/arch/arm/boot/Image $BUILD_RESULTS/$PI_VERSION/${IMAGE_NAME[${PI_VERSION}]}

  echo "### installing kernel modules"
  mkdir -p $BUILD_RESULTS/$PI_VERSION/modules
  ARCH=arm CROSS_COMPILE=${CCPREFIX[${PI_VERSION}]} INSTALL_MOD_PATH=$BUILD_RESULTS/$PI_VERSION/modules make modules_install -j$NUM_CPUS

  # remove symlinks, mustn't be part of raspberrypi-bootloader*.deb
  echo "### removing symlinks"
  rm -f $BUILD_RESULTS/$PI_VERSION/modules/lib/modules/*/build
  rm -f $BUILD_RESULTS/$PI_VERSION/modules/lib/modules/*/source

  if [[ ! -z $CIRCLE_ARTIFACTS ]]; then
    cp ../*.deb $CIRCLE_ARTIFACTS
  fi
  mv ../*.deb $BUILD_RESULTS
  echo "###############"
  echo "### END building kernel for ${PI_VERSION}"
  echo "### Check the $BUILD_RESULTS/$PI_VERSION/kernel.img and $BUILD_RESULTS/$PI_VERSION/modules directory on your host machine."
}

function create_kernel_deb_packages () {
  echo "###############"
  echo "### START building kernel DEBIAN PACKAGES"

  PKG_TMP=`mktemp -d`

  NEW_KERNEL=$PKG_TMP/raspberrypi-kernel-${NEW_VERSION}

  create_dir_for_build_user $NEW_KERNEL

  # copy over source files for building the packages
  echo "copying firmware from $RASPBERRY_FIRMWARE to $NEW_KERNEL"
  # skip modules directory from standard tree, because we will our on modules below
  tar --exclude=modules -C $RASPBERRY_FIRMWARE -cf - . | tar -C $NEW_KERNEL -xvf -
  # create an empty modules directory, because we have skipped this above
  mkdir -p $NEW_KERNEL/modules/
  cp -r $SRC_DIR/debian $NEW_KERNEL/debian
  touch $NEW_KERNEL/debian/files

  for pi_version in ${!CCPREFIX[@]}; do
    cp $BUILD_RESULTS/$pi_version/${IMAGE_NAME[${pi_version}]} $NEW_KERNEL/boot
    cp -R $BUILD_RESULTS/$pi_version/modules/lib/modules/* $NEW_KERNEL/modules
  done
  # build debian packages
  cd $NEW_KERNEL

  dch -v ${NEW_VERSION} --package raspberrypi-firmware 'add Hypriot custom kernel'
  debuild --no-lintian -ePATH=${PATH}:$ARM_TOOLS/$X64_CROSS_COMPILE_CHAIN/bin -b -aarmhf -us -uc
  cp ../*.deb $BUILD_RESULTS
  if [[ ! -z $CIRCLE_ARTIFACTS ]]; then
    cp ../*.deb $CIRCLE_ARTIFACTS
  fi

  echo "###############"
  echo "### FINISH building kernel DEBIAN PACKAGES"
}


##############
###  main  ###
##############

echo "*** all parameters are set ***"
echo "*** the kernel timestamp is: $NEW_VERSION ***"
echo "#############################################"

# clear build cache to fetch the current raspberry/firmware
sudo rm -fr $RASPBERRY_FIRMWARE

# setup necessary build environment: dir, repos, etc.
prepare_kernel_building

# create kernel, associated modules
for pi_version in ${!CCPREFIX[@]}; do
  create_kernel_for $pi_version
done

# create kernel packages
create_kernel_deb_packages

# running in vagrant VM
if [ -d /vagrant ]; then
  # copy build results to synced vagrant host folder
  FINAL_BUILD_RESULTS=/vagrant/build_results/$NEW_VERSION
else
  # running in drone build
  FINAL_BUILD_RESULTS=$SRC_DIR/output/$NEW_VERSION
fi

echo "###############"
echo "### Copy deb packages to $FINAL_BUILD_RESULTS"
mkdir -p $FINAL_BUILD_RESULTS
cp $BUILD_RESULTS/*.deb $FINAL_BUILD_RESULTS
cp $BUILD_RESULTS/*.txt $FINAL_BUILD_RESULTS

ls -lh $FINAL_BUILD_RESULTS
echo "*** kernel build done"
