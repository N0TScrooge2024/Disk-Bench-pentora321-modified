#!/bin/bash

# ============================================================
# Disk Benchmark Script
# Original by MOHAMMAD REFAEI (modified)
# Version 2.5
#
# Changes in version 2.5:
# - Changed iostat output to human-readable format (--human) with 10-second interval.
# - This provides cleaner, easier-to-read disk statistics during tests.
# ============================================================

# Set locale to C for predictable command output
export LC_ALL=C

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'
BOLD='\033[1m'
RESET='\033[0m'

# Trap to clean up on exit or interrupt
trap cleanup_and_exit INT TERM EXIT

# Global variables
MOUNT_POINT=""
TEST_FILE=""
DISK=""
TEST_CHOICE=""
DD_BLOCK_SIZE_MB=1    # Fixed block size in MB for reliable testing
DD_COUNT=""           # Number of blocks (will be computed from GB input)
PARTITION_PATH=""
CLEANUP_NEEDED=false

# Flags for optional tools
USE_PV=false
PV_SUPPORTS_DIRECT=false
IOSTAT_PANE_ID=""

# ------------------------------------------------------------------
# Helper functions
# ------------------------------------------------------------------

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}This script must be run as root!${RESET}"
        exit 1
    fi
}

# Check required commands
check_dependencies() {
    local missing=()
    for cmd in dd parted mkfs.ext4 wipefs hdparm lsblk mount umount grep awk; do
        if ! command -v $cmd &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${RED}Missing required commands: ${missing[*]}${RESET}"
        exit 1
    fi

    # Check for optional pv
    if command -v pv &>/dev/null; then
        USE_PV=true
        # Check if pv supports direct I/O (-D)
        if pv -D /dev/null </dev/null 2>/dev/null; then
            PV_SUPPORTS_DIRECT=true
            echo -e "${GREEN}PV found and supports direct I/O. Will use pv for progress.${RESET}"
        else
            echo -e "${YELLOW}PV found but does NOT support direct I/O. Falling back to dd.${RESET}"
            USE_PV=false
        fi
    else
        echo -e "${YELLOW}PV not found. Using dd for I/O tests.${RESET}"
    fi
}

# List available disks with more details
list_disks() {
    echo -e "${BOLD}${CYAN}Available disks (NAME, SIZE, MODEL):${RESET}"
    lsblk -d -o NAME,SIZE,MODEL,TYPE | grep disk
}

# Check if the selected disk is a system disk (contains root partition)
check_system_disk() {
    local disk=$1
    # Get all partitions of this disk
    local partitions
    partitions=$(lsblk -ln -o NAME,MOUNTPOINT "/dev/$disk" | awk '{print $1}')
    for part in $partitions; do
        # Check if any partition is mounted as root
        if mount | grep -q "^/dev/$part on / "; then
            return 0  # system disk found
        fi
    done
    return 1  # not a system disk
}

# Get user input with validation
get_user_inputs() {
    echo -e "\n${BOLD}${CYAN}Disk Benchmark Setup${RESET}"
    list_disks

    # Disk selection
    while true; do
        read -p "Enter the disk to test (e.g., sdb, nvme0n1): " DISK
        if [[ -z "$DISK" ]]; then
            echo -e "${RED}Disk name cannot be empty.${RESET}"
            continue
        fi
        if [[ ! -e "/dev/$DISK" ]]; then
            echo -e "${RED}Device /dev/$DISK does not exist.${RESET}"
            continue
        fi
        # Ensure it's a block device and a disk (not a partition)
        if [[ ! -b "/dev/$DISK" ]]; then
            echo -e "${RED}/dev/$DISK is not a block device.${RESET}"
            continue
        fi
        # Check if it's a disk (has no parent disk in lsblk hierarchy)
        if ! lsblk -d -n -o NAME "/dev/$DISK" &>/dev/null; then
            echo -e "${RED}/dev/$DISK is a partition, not a whole disk.${RESET}"
            continue
        fi
        break
    done

    # Test type selection
    echo -e "\n${BOLD}${CYAN}Test type:${RESET}"
    echo "  1) DD write/read test only"
    echo "  2) hdparm test only (non-destructive)"
    echo "  3) Both tests (DD + hdparm)"
    read -p "Enter your choice (1/2/3): " TEST_CHOICE

    if [[ "$TEST_CHOICE" == "1" || "$TEST_CHOICE" == "3" ]]; then
        # Ask for total size in GB or 'full'
        while true; do
            read -p "Enter total test size in GB, or 'full' to use entire disk: " size_input
            if [[ "$size_input" == "full" ]]; then
                # Get disk size in bytes
                local disk_bytes
                disk_bytes=$(lsblk -b -n -o SIZE "/dev/$DISK" 2>/dev/null | head -1)
                if [[ -z "$disk_bytes" || "$disk_bytes" -eq 0 ]]; then
                    echo -e "${RED}Failed to determine disk size.${RESET}"
                    exit 1
                fi
                # Convert to GB (integer, floor)
                total_size_gb=$((disk_bytes / 1024 / 1024 / 1024))
                if [[ $total_size_gb -eq 0 ]]; then
                    echo -e "${RED}Disk is smaller than 1 GB. Cannot test.${RESET}"
                    exit 1
                fi
                echo -e "${YELLOW}Using full disk size: ${total_size_gb} GB${RESET}"
                break
            elif [[ "$size_input" =~ ^[0-9]+$ ]] && [[ $size_input -gt 0 ]]; then
                total_size_gb=$size_input
                break
            else
                echo -e "${RED}Invalid size. Please enter a positive integer or 'full'.${RESET}"
            fi
        done

        # Compute count based on 1M blocks
        DD_COUNT=$((total_size_gb * 1024 / DD_BLOCK_SIZE_MB))
        if [[ $DD_COUNT -eq 0 ]]; then
            echo -e "${RED}Total test size too small. Use at least 1 GB.${RESET}"
            exit 1
        fi

        echo -e "${YELLOW}Selected disk: /dev/$DISK${RESET}"
        echo -e "${YELLOW}Total test size: ${total_size_gb} GB (${DD_COUNT} blocks of ${DD_BLOCK_SIZE_MB} MB)${RESET}"
    fi

    # Warn if disk is system disk
    if check_system_disk "$DISK"; then
        echo -e "${RED}${BOLD}WARNING: /dev/$DISK appears to be a system disk (contains root partition).${RESET}"
        echo -e "${RED}Continuing may cause data loss and break your system!${RESET}"
        read -p "Are you absolutely sure you want to continue? (yes/no): " sys_confirm
        if [[ "$sys_confirm" != "yes" ]]; then
            echo -e "${GREEN}Aborted.${RESET}"
            exit 0
        fi
    fi

    # Confirmation before proceeding with destructive operations
    if [[ "$TEST_CHOICE" == "1" || "$TEST_CHOICE" == "3" ]]; then
        echo -e "\n${RED}${BOLD}WARNING: This will DESTROY ALL DATA on /dev/$DISK!${RESET}"
        read -p "Are you sure you want to continue? (yes/no): " confirm
        if [[ "$confirm" != "yes" ]]; then
            echo -e "${GREEN}Aborted.${RESET}"
            exit 0
        fi
    fi
}

# Check if the disk is currently in use (mounted or swap)
check_disk_in_use() {
    # Check if any partition is mounted
    if mount | grep -q "/dev/$DISK"; then
        echo -e "${RED}Disk /dev/$DISK has mounted partitions. Aborting.${RESET}"
        exit 1
    fi
    # Check if the whole disk is used as swap
    if swapon --show | grep -q "/dev/$DISK"; then
        echo -e "${RED}Disk /dev/$DISK is used as swap. Aborting.${RESET}"
        exit 1
    fi
    # Also check if any process has the disk open (lsof may be optional)
    if command -v lsof &>/dev/null; then
        if lsof "/dev/$DISK" &>/dev/null; then
            echo -e "${RED}Disk /dev/$DISK is in use by a process. Aborting.${RESET}"
            exit 1
        fi
    fi
}

# Start iostat in a tmux pane if possible
start_iostat_pane() {
    if [[ -n "$TMUX" ]] && command -v tmux &>/dev/null; then
        echo -e "${GREEN}Running inside tmux. Splitting window horizontally for iostat...${RESET}"
        # Create a new pane below (horizontal split) with 40% height,
        # do not switch focus to it (-d), and capture its pane ID
        IOSTAT_PANE_ID=$(tmux split-window -v -l 40% -d -P -F "#{pane_id}")
        if [[ -z "$IOSTAT_PANE_ID" ]]; then
            echo -e "${YELLOW}Failed to create tmux pane. Continuing without iostat.${RESET}"
            return 1
        fi
        # Send iostat command with human-readable output and 10-second interval
        tmux send-keys -t "$IOSTAT_PANE_ID" "iostat --human $DISK 10; echo 'Press any key to close...'; read" Enter
        sleep 1  # give iostat a moment to start
        return 0
    else
        echo -e "${YELLOW}Not running inside tmux or tmux not available. Skipping iostat monitoring.${RESET}"
        return 1
    fi
}

# Stop iostat pane if it was started
stop_iostat_pane() {
    if [[ -n "$IOSTAT_PANE_ID" ]] && command -v tmux &>/dev/null; then
        tmux kill-pane -t "$IOSTAT_PANE_ID" 2>/dev/null
        IOSTAT_PANE_ID=""
    fi
}

# Perform write test using either dd or pv
run_write_test() {
    local test_file="$1"
    local count="$2"
    local block_size_mb="$3"
    local bytes=$((count * block_size_mb * 1024 * 1024))

    echo -e "${BOLD}${CYAN}Running write test...${RESET}"
    if [[ "$USE_PV" == true ]] && [[ "$PV_SUPPORTS_DIRECT" == true ]]; then
        # Use pv with direct I/O, capture stderr for speed parsing
        local pv_output
        pv_output=$(pv -f -W -s "$bytes" -D "/dev/$DISK" /dev/zero > "$test_file" 2>&1)
        local ret=$?
        if [[ $ret -eq 0 ]]; then
            echo -e "${GREEN}Write test completed with pv.${RESET}"
        else
            echo -e "${RED}Write test failed (pv).${RESET}"
            return 1
        fi
        # Parse speed from pv's stderr (last line)
        write_speed=$(echo "$pv_output" | tail -1 | grep -oE '[0-9]+(\.[0-9]+)?[[:space:]]*[KMGT]?B/s')
        [[ -z "$write_speed" ]] && write_speed="(could not parse)"
        echo -e "${GREEN}Write speed (pv): $write_speed${RESET}"
    else
        # Use dd with direct I/O
        dd if=/dev/zero of="$test_file" bs=${block_size_mb}M count=$count oflag=direct status=progress 2> dd_write.log
        local ret=$?
        if [[ $ret -ne 0 ]]; then
            echo -e "${RED}Write test failed (dd). Check dd_write.log${RESET}"
            return 1
        fi
        write_speed=$(grep -E -o '[0-9]+(\.[0-9]+)? [KMG]?B/s' dd_write.log | tail -1)
        [[ -z "$write_speed" ]] && write_speed="(could not parse)"
        echo -e "${GREEN}Write speed (dd): $write_speed${RESET}"
        rm -f dd_write.log
    fi
    return 0
}

# Perform read test using either dd or pv
run_read_test() {
    local test_file="$1"
    local count="$2"
    local block_size_mb="$3"
    local bytes=$((count * block_size_mb * 1024 * 1024))

    echo -e "${BOLD}${CYAN}Running read test...${RESET}"
    if [[ "$USE_PV" == true ]] && [[ "$PV_SUPPORTS_DIRECT" == true ]]; then
        # Use pv with direct I/O, capture stderr for speed parsing
        local pv_output
        pv_output=$(pv -f -W -s "$bytes" -D "$test_file" "$test_file" > /dev/null 2>&1)
        local ret=$?
        if [[ $ret -eq 0 ]]; then
            echo -e "${GREEN}Read test completed with pv.${RESET}"
        else
            echo -e "${RED}Read test failed (pv).${RESET}"
            return 1
        fi
        # Parse speed from pv's stderr (last line)
        read_speed=$(echo "$pv_output" | tail -1 | grep -oE '[0-9]+(\.[0-9]+)?[[:space:]]*[KMGT]?B/s')
        [[ -z "$read_speed" ]] && read_speed="(could not parse)"
        echo -e "${GREEN}Read speed (pv): $read_speed${RESET}"
    else
        # Use dd with direct I/O
        dd if="$test_file" of=/dev/null bs=${block_size_mb}M iflag=direct status=progress 2> dd_read.log
        local ret=$?
        if [[ $ret -ne 0 ]]; then
            echo -e "${RED}Read test failed (dd). Check dd_read.log${RESET}"
            return 1
        fi
        read_speed=$(grep -E -o '[0-9]+(\.[0-9]+)? [KMG]?B/s' dd_read.log | tail -1)
        [[ -z "$read_speed" ]] && read_speed="(could not parse)"
        echo -e "${GREEN}Read speed (dd): $read_speed${RESET}"
        rm -f dd_read.log
    fi
    return 0
}

# Run DD test (sequential write/read)
run_dd_test() {
    # Start iostat pane if possible
    start_iostat_pane

    # Perform write test
    if ! run_write_test "$TEST_FILE" "$DD_COUNT" "$DD_BLOCK_SIZE_MB"; then
        stop_iostat_pane
        exit 1
    fi

    # Perform read test
    if ! run_read_test "$TEST_FILE" "$DD_COUNT" "$DD_BLOCK_SIZE_MB"; then
        stop_iostat_pane
        exit 1
    fi

    echo -e "\n${GREEN}${BOLD}DD Test Results:${RESET}"
    echo -e "  ${YELLOW}Write speed:${RESET} $write_speed"
    echo -e "  ${YELLOW}Read speed:${RESET} $read_speed"

    # Stop iostat pane
    stop_iostat_pane
}

# Run hdparm test (non-destructive, works on the raw disk)
run_hdparm_test() {
    echo -e "${BOLD}${CYAN}Running hdparm test on /dev/$DISK...${RESET}"
    hdparm -Tt "/dev/$DISK" | tee hdparm_output.log

    cached_speed=$(grep "Timing cached reads" hdparm_output.log | awk '{print $(NF-1), $NF}')
    buffered_speed=$(grep "Timing buffered disk reads" hdparm_output.log | awk '{print $(NF-1), $NF}')

    echo -e "\n${GREEN}${BOLD}hdparm Test Results:${RESET}"
    echo -e "  ${YELLOW}Cached reads:${RESET} $cached_speed"
    echo -e "  ${YELLOW}Buffered reads:${RESET} $buffered_speed"

    rm -f hdparm_output.log
}

# Partition and format the disk (create one ext4 partition)
partition_and_format() {
    echo -e "${BOLD}${CYAN}Preparing disk /dev/$DISK...${RESET}"

    # Wipe any existing signatures
    wipefs -a "/dev/$DISK" || { echo -e "${RED}Failed to wipe disk.${RESET}"; exit 1; }

    # Create GPT partition table
    if ! parted "/dev/$DISK" mklabel gpt; then
        echo -e "${RED}Failed to create GPT label.${RESET}"
        exit 1
    fi

    # Create a single partition using all space
    if ! parted "/dev/$DISK" mkpart primary ext4 0% 100%; then
        echo -e "${RED}Failed to create partition.${RESET}"
        exit 1
    fi

    # Let udev settle
    sleep 2

    # Get the first partition (most likely the only one)
    # Regex matches both sda1 and nvme0n1p1 patterns
    PARTITION_PATH=$(lsblk -ln -o NAME "/dev/$DISK" | grep -E "^${DISK}(p[0-9]+|[0-9]+)$" | head -n1)
    if [[ -z "$PARTITION_PATH" ]]; then
        echo -e "${RED}Partition creation failed. Exiting.${RESET}"
        exit 1
    fi
    PARTITION_PATH="/dev/$PARTITION_PATH"

    echo -e "${GREEN}Partition created: $PARTITION_PATH${RESET}"

    # Format as ext4
    mkfs.ext4 -F "$PARTITION_PATH" || { echo -e "${RED}Formatting failed.${RESET}"; exit 1; }

    # Create a unique mount point (with PID to avoid conflicts)
    MOUNT_POINT="/mnt/disk_bench_$$"
    mkdir -p "$MOUNT_POINT" || { echo -e "${RED}Cannot create mount point.${RESET}"; exit 1; }

    mount "$PARTITION_PATH" "$MOUNT_POINT" || { echo -e "${RED}Mount failed.${RESET}"; exit 1; }

    TEST_FILE="$MOUNT_POINT/dd_test.img"
    CLEANUP_NEEDED=true

    echo -e "${GREEN}Partition mounted at $MOUNT_POINT${RESET}"
}

# Cleanup: unmount, remove mount point, wipe disk (if we created a partition)
cleanup_and_exit() {
    if [[ "$CLEANUP_NEEDED" == true ]]; then
        echo -e "\n${BOLD}${CYAN}Cleaning up...${RESET}"
        if mountpoint -q "$MOUNT_POINT"; then
            umount "$MOUNT_POINT" 2>/dev/null
        fi
        rm -rf "$MOUNT_POINT" 2>/dev/null

        echo -e "${RED}Wiping partition table on /dev/$DISK...${RESET}"
        wipefs -a "/dev/$DISK" 2>/dev/null
        parted "/dev/$DISK" mklabel gpt 2>/dev/null

        echo -e "${GREEN}Cleanup complete. Disk /dev/$DISK is now empty.${RESET}"
    fi
    # Ensure iostat pane is killed if still running
    stop_iostat_pane
}

# ------------------------------------------------------------------
# Main execution
# ------------------------------------------------------------------
check_root
check_dependencies

# If tmux is available and we are NOT already inside tmux, re-run inside a new tmux session
if command -v tmux &>/dev/null && [[ -z "$TMUX" ]]; then
    echo -e "${GREEN}tmux is available. Re-launching script inside tmux for iostat monitoring...${RESET}"
    exec tmux new-session "$0"
    # exec replaces the current process, so the script will not continue here
fi

# If we are inside tmux (TMUX is set) or tmux not available, continue normally
get_user_inputs

case "$TEST_CHOICE" in
    1)
        check_disk_in_use
        partition_and_format
        run_dd_test
        # cleanup will be triggered by trap
        ;;
    2)
        # hdparm test only, non-destructive, no cleanup needed
        run_hdparm_test
        # disable cleanup trap for normal exit (but keep for signals)
        trap - EXIT
        ;;
    3)
        check_disk_in_use
        partition_and_format
        run_dd_test
        run_hdparm_test
        # cleanup via trap
        ;;
    *)
        echo -e "${RED}Invalid choice.${RESET}"
        exit 1
        ;;
esac

exit 0
