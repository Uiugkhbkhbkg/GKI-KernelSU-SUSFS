#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Maximum number of concurrent builds
MAX_CONCURRENT_BUILDS=4

# Check if 'builds' folder exists, create it if not
if [ ! -d "./builds" ]; then
    echo "'builds' folder not found. Creating it..."
    mkdir -p ./builds
else
    echo "'builds' folder already exists."
fi

cd ./builds
ROOT_DIR="GKI-AIO-$(date +'%Y-%m-%d-%I-%M-%p')-release"
echo "Creating root folder: $ROOT_DIR..."
mkdir -p "$ROOT_DIR"
cd "$ROOT_DIR"

# Array with configurations (e.g., android-version-kernel-version-date)
BUILD_CONFIGS=(
    "android12-5.10-198-2024-01"
    "android12-5.10-205-2024-03"
    "android12-5.10-209-2024-05"
    "android12-5.10-218-2024-08"
    "android12-5.10-66-2022-09"
    
    #"android15-6.6-30-2024-08"
)


# Arrays to store generated zip files, grouped by androidversion-kernelversion
declare -A RELEASE_ZIPS=()

# Iterate over configurations
build_config() {
    CONFIG=$1
    CONFIG_DETAILS=${CONFIG}

    # Create a directory named after the current configuration
    echo "Creating folder for configuration: $CONFIG..."
    mkdir -p "$CONFIG"
    cd "$CONFIG"
    
    # Split the config details into individual components
    IFS="-" read -r ANDROID_VERSION KERNEL_VERSION SUB_LEVEL DATE <<< "$CONFIG_DETAILS"
    
    # Formatted branch name for each build (e.g., android14-5.15-2024-01)
    FORMATTED_BRANCH="${ANDROID_VERSION}-${KERNEL_VERSION}-${DATE}"

     # Log file for this build in case of failure
    LOG_FILE="../${CONFIG}_build.log"
    echo "Starting build for $CONFIG using branch $FORMATTED_BRANCH..."

    # Function to capture errors and log them
    handle_failure() {
        if [ $? -ne 0 ]; then
            echo "Build failed for $CONFIG. Saving logs to $LOG_FILE."
            exec &> "$LOG_FILE"  # Redirect all future output to the log file
            echo "== ERROR LOG FOR $CONFIG =="

            # Run cleanup actions if needed
            echo "Cleaning up failed build directory..."
            rm -rf "$CONFIG"  # Example cleanup action

            echo "Logs saved to $LOG_FILE."
        fi
    }

    # Set a trap to handle errors
    trap 'handle_failure' ERR

    echo "Starting build for $CONFIG using branch $FORMATTED_BRANCH..."

       # Check if AnyKernel3 repo exists, remove it if it does
    if [ -d "./AnyKernel3" ]; then
        echo "Removing existing AnyKernel3 directory..."
        rm -rf ./AnyKernel3
    fi
    echo "Cloning AnyKernel3 repository..."
    git clone https://github.com/TheWildJames/AnyKernel3.git -b "${ANDROID_VERSION}-${KERNEL_VERSION}"

    # Check if susfs4ksu repo exists, remove it if it does
    if [ -d "./susfs4ksu" ]; then
        echo "Removing existing susfs4ksu directory..."
        rm -rf ./susfs4ksu
    fi
    echo "Cloning susfs4ksu repository..."
    git clone https://gitlab.com/simonpunk/susfs4ksu.git -b "gki-${ANDROID_VERSION}-${KERNEL_VERSION}"

    # Setup directory for each build
    mkdir -p "$CONFIG"
    cd "$CONFIG"

    # Initialize and sync kernel source with updated repo commands
    echo "Initializing and syncing kernel source..."
    repo init --depth=1 --u https://android.googlesource.com/kernel/manifest -b common-${FORMATTED_BRANCH}
    REMOTE_BRANCH=$(git ls-remote https://android.googlesource.com/kernel/common ${FORMATTED_BRANCH})
    DEFAULT_MANIFEST_PATH=.repo/manifests/default.xml
    
    # Check if the branch is deprecated and adjust the manifest
    if grep -q deprecated <<< $REMOTE_BRANCH; then
        echo "Found deprecated branch: $FORMATTED_BRANCH"
        sed -i "s/\"${FORMATTED_BRANCH}\"/\"deprecated\/${FORMATTED_BRANCH}\"/g" $DEFAULT_MANIFEST_PATH
    fi

    # Verify repo version and sync
    repo --version
    repo --trace sync -c -j$(nproc --all) --no-tags

    # Apply KernelSU and SUSFS patches
    echo "Adding KernelSU..."
    curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -

    echo "Applying SUSFS patches..."
    cp ../susfs4ksu/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch ./KernelSU/
    cp ../susfs4ksu/kernel_patches/50_add_susfs_in_gki-${ANDROID_VERSION}-${KERNEL_VERSION}.patch ./common/
    cp ../susfs4ksu/kernel_patches/fs/susfs.c ./common/fs/
    cp ../susfs4ksu/kernel_patches/include/linux/susfs.h ./common/include/linux/
    cp ../susfs4ksu/kernel_patches/fs/sus_su.c ./common/fs/
    cp ../susfs4ksu/kernel_patches/include/linux/sus_su.h ./common/include/linux/

    # Apply the patches
    cd ./KernelSU
    patch -p1 < 10_enable_susfs_for_ksu.patch
    cd ../common
    patch -p1 < 50_add_susfs_in_gki-${ANDROID_VERSION}-${KERNEL_VERSION}.patch
    cd ..

    # Add configuration settings for SUSFS
    echo "Adding configuration settings to gki_defconfig..."
    echo "CONFIG_KSU=y" >> ./common/arch/arm64/configs/gki_defconfig
    echo "CONFIG_KSU_SUSFS=y" >> ./common/arch/arm64/configs/gki_defconfig
    echo "CONFIG_KSU_SUSFS_SUS_PATH=y" >> ./common/arch/arm64/configs/gki_defconfig
    echo "CONFIG_KSU_SUSFS_SUS_MOUNT=y" >> ./common/arch/arm64/configs/gki_defconfig
    echo "CONFIG_KSU_SUSFS_SUS_KSTAT=y" >> ./common/arch/arm64/configs/gki_defconfig
    echo "CONFIG_KSU_SUSFS_SUS_OVERLAYFS=y" >> ./common/arch/arm64/configs/gki_defconfig
    echo "CONFIG_KSU_SUSFS_TRY_UMOUNT=y" >> ./common/arch/arm64/configs/gki_defconfig
    echo "CONFIG_KSU_SUSFS_SPOOF_UNAME=y" >> ./common/arch/arm64/configs/gki_defconfig
    echo "CONFIG_KSU_SUSFS_ENABLE_LOG=y" >> ./common/arch/arm64/configs/gki_defconfig
    echo "CONFIG_KSU_SUSFS_OPEN_REDIRECT=y" >> ./common/arch/arm64/configs/gki_defconfig
    echo "CONFIG_KSU_SUSFS_SUS_SU=y" >> ./common/arch/arm64/configs/gki_defconfig

    # Build kernel
    echo "Building kernel for $CONFIG..."

    # Check if build.sh exists, if it does, run the default build script
    if [ -e build/build.sh ]; then
        echo "build.sh found, running default build script..."
        # Modify config files for the default build process
        sed -i '2s/check_defconfig//' ./common/build.config.gki
        sed -i "s/dirty/''/g" ./common/scripts/setlocalversion
        LTO=thin BUILD_CONFIG=common/build.config.gki.aarch64 build/build.sh
    
        # Instead of copying to AnyKernel3 outside, copy within the current config directory
        echo "Copying Image.lz4 to $CONFIG/AnyKernel3..."
        cp ./out/${ANDROID_VERSION}-${KERNEL_VERSION}/dist/Image.lz4 ../AnyKernel3/Image.lz4
    else
        echo "build.sh found, using it for build..."
        # Use Bazel build if build.sh exists
        echo "Running Bazel build..."
        sed -i "/stable_scmversion_cmd/s/-maybe-dirty/+/g" ./build/kernel/kleaf/impl/stamp.bzl
        sed -i '2s/check_defconfig//' ./common/build.config.gki
        rm -rf ./common/android/abi_gki_protected_exports_aarch64
        rm -rf ./common/android/abi_gki_protected_exports_x86_64
        tools/bazel build --config=fast //common:kernel_aarch64_dist

        # Instead of copying to AnyKernel3 outside, copy within the current config directory
        echo "Copying Image.lz4 to $CONFIG/AnyKernel3..."
        cp ./bazel-bin/common/kernel_aarch64/Image.lz4 ../AnyKernel3/Image.lz4
    fi

    # Create zip in the same directory
    cd ../AnyKernel3
    ZIP_NAME="AnyKernel3-${ANDROID_VERSION}-${KERNEL_VERSION}.${SUB_LEVEL}_${DATE}.zip"
    echo "Creating zip file: $ZIP_NAME..."
    zip -r "../../$ZIP_NAME" ./*
    cd ../../

    # Group the zip file by Android and Kernel version
    RELEASE_ZIPS["$ANDROID_VERSION-$KERNEL_VERSION.$SUB_LEVEL"]+="./$ZIP_NAME "

    # Delete the $CONFIG folder after building
    echo "Deleting $CONFIG folder..."
    rm -rf "$CONFIG"
}

# Concurrent build management
JOBS=()
for CONFIG in "${BUILD_CONFIGS[@]}"; do
    build_config "$CONFIG" &  # Start the build in the background
    JOBS+=($!)               # Track the background job ID

    # Limit the number of concurrent builds
    while [ "$(jobs -r | wc -l)" -ge "$MAX_CONCURRENT_BUILDS" ]; do
        sleep 1
    done
done

# Wait for all jobs to finish
for JOB in "${JOBS[@]}"; do
    wait "$JOB"
done

echo "Build process complete."

# Collect all zip files
ZIP_FILES=($(find ./ -type f -name "*.zip"))

# GitHub repository details
REPO_OWNER="TheWildJames"
REPO_NAME="GKI-KernelSU-SUSFS"
TAG_NAME="v$(date +'%Y.%m.%d-%H%M%S')"
RELEASE_NAME="GKI Kernels With KernelSU & SUSFS"
RELEASE_NOTES="This release contains the following builds:
$(printf '%s\n' "${ZIP_FILES[@]}")"

# Create the GitHub release
echo "Creating GitHub release: $RELEASE_NAME..."
gh release create "$TAG_NAME" "${ZIP_FILES[@]}" \
    --repo "$REPO_OWNER/$REPO_NAME" \
    --title "$RELEASE_NAME" \
    --notes "$RELEASE_NOTES"

echo "GitHub release created with the following files:"
printf '%s\n' "${ZIP_FILES[@]}"

