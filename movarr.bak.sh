#!/bin/bash

# Get the path to the movarr directory
scriptDir="$(cd -- "$(dirname "$0")" >/dev/null 2>&1; pwd -P)"

# Read configuration from file
configFile="$scriptDir/config.ini"
if [ -f "$configFile" ]; then
    . "$configFile"
else
    logMessage "error" "Configuration file '$configFile' not found."
    exit 1
fi

# Generate a timestamp for the log file
# logFilePrefix="movarr_log_"
# logFile="$scriptDir/logs/$logFilePrefix$(date +"%Y%m%d-%H%M%S").txt"
logFile="$scriptDir/logs/movarr.log"

# Dynamically generate diskPaths based on directories in /mnt matching the pattern disk# or disk##
diskPaths=("/mnt/disk"[0-9]*)

# Check if any disks are found
if [ ${#diskPaths[@]} -eq 0 ]; then
    logMessage "error" "No disks found in /mnt matching the pattern disk##."
    exit 1
fi

sourceDirs=$sourceDirectories

# Set start time
startTime=$(date +%s)

# Function to log messages based on log level
logMessage() {
    local logLevel="$1"
    shift
    local logMessage="$@"

    case "$logLevel" in
        "debug")
            # Print debug messages to the console for troubleshooting
            echo "$(date +"%Y-%m-%d %H:%M:%S") [DEBUG]: $logMessage"
            ;;
        "info" | "warn" | "error")
            # Log messages to the specified log file
            echo "$(date +"%Y-%m-%d %H:%M:%S") [$logLevel]: $logMessage" >>"$logFile"

            # Use Unraid's notifications based on the log level (excluding debug)
            if [ "$logLevel" != "debug" ]; then
                case "$logLevel" in
                    "info")
                        # /usr/local/emhttp/webGui/scripts/notify -i normal -s "$logMessage"
                        ;;
                    "warn")
                        # /usr/local/emhttp/webGui/scripts/notify -i warning -s "$logMessage"
                        ;;
                    "error")
                        # /usr/local/emhttp/webGui/scripts/notify -i alert -s "$logMessage"
                        ;;
                    *)
                        echo "$(date +"%Y-%m-%d %H:%M:%S") [ERROR]: Invalid log level '$logLevel'" >>"$logFile"
                        ;;
                esac
            fi
            ;;
        *)
            echo "$(date +"%Y-%m-%d %H:%M:%S") [ERROR]: Invalid log level '$logLevel'" >>"$logFile"
            ;;
    esac
}

# Function to validate configuration
validateConfiguration() {
    local errors=0

    # Check if any required variables are missing
    requiredVars=("simulationMode" "backgroundTasks" "logLevel" "sourceFreeLimit" "destinationFreeLimit" "maxRollovers" "sourceDirectories" "excludeMoveTo" "moverMode")
    for var in "${requiredVars[@]}"; do
        if [ -z "${!var}" ]; then
            logMessage "error" "Required variable '$var' not set in '$configFile'."
            ((errors++))
        fi
    done

    # Validate simulationMode (should be true or false)
    if [ "$simulationMode" != "true" ] && [ "$simulationMode" != "false" ]; then
        logMessage "error" "Invalid value for 'simulationMode'. It should be either 'true' or 'false'."
        ((errors++))
    fi

    # Validate backgroundTasks (should be true or false)
    if [ "$backgroundTasks" != "true" ] && [ "$backgroundTasks" != "false" ]; then
        logMessage "error" "Invalid value for 'backgroundTasks'. It should be either 'true' or 'false'."
        ((errors++))
    fi

    # Validate logLevel (should be debug, info, warn, or error)
    if [ "$logLevel" != "debug" ] && [ "$logLevel" != "info" ] && [ "$logLevel" != "warn" ] && [ "$logLevel" != "error" ]; then
        logMessage "error" "Invalid value for 'logLevel'. It should be one of: debug, info, warn, error."
        ((errors++))
    fi

    # Validate sourceFreeLimit (should be a positive integer)
    if ! [[ "$sourceFreeLimit" =~ ^[1-9][0-9]*$ ]]; then
        logMessage "error" "Invalid value for 'sourceFreeLimit'. It should be a positive integer."
        ((errors++))
    fi

    # Validate destinationFreeLimit (should be a positive integer)
    if ! [[ "$destinationFreeLimit" =~ ^[1-9][0-9]*$ ]]; then
        logMessage "error" "Invalid value for 'destinationFreeLimit'. It should be a positive integer."
        ((errors++))
    fi

    # Validate maxRollovers (should be a positive integer)
    if ! [[ "$maxRollovers" =~ ^[1-9][0-9]*$ ]]; then
        logMessage "error" "Invalid value for 'maxRollovers'. It should be a positive integer."
        ((errors++))
    fi

    # Validate moverMode (should be largest, smallest, or random)
    if [ "$moverMode" != "largest" ] && [ "$moverMode" != "smallest" ] && [ "$moverMode" != "random" ]; then
        logMessage "error" "Invalid value for 'moverMode'. It should be one of: largest, smallest, random."
        ((errors++))
    fi

    if [ "$errors" -gt 0 ]; then
        exit 1
    fi
}

# Validate configuration
validateConfiguration

# Function to check if a disk should be excluded from searching
shouldExcludeSearch() {
    local diskName="$1"
    for excludedDisk in "${excludeSearch[@]}"; do
        [[ $diskName == $excludedDisk ]] && return 0
    done
    return 1
}

# Function to check if a disk should be excluded from moving data to
shouldExcludeMoveTo() {
    local diskName="$1"
    for excludedDisk in "${excludeMoveTo[@]}"; do
        [[ $diskName == $excludedDisk ]] && return 0
    done
    return 1
}

# Function to get the free space of a disk
getFreeSpace() {
    df -BG "$1" | awk 'NR==2 {print $4}' | sed 's/G//'
}

# Function to find the disk with the least free space greater than a specified value
findLeastFreeDisk() {
    local minFree="$1"
    local leastFreeDisk=""

    for diskPath in "${diskPaths[@]}"; do
        diskName=$(basename "$diskPath")

        # Check if the disk should be excluded from searching
        if shouldExcludeSearch "$diskName"; then
            continue
        fi

        freeSpace=$(getFreeSpace "$diskPath")

        if [[ $freeSpace -gt $minFree ]]; then
            # Check if the disk should be excluded from moving data to
            if shouldExcludeMoveTo "$diskName"; then
                continue
            fi

            if [[ -z $leastFreeDisk || $freeSpace -lt $(getFreeSpace "$leastFreeDisk") ]]; then
                leastFreeDisk="$diskPath"
            fi
        fi
    done

    echo "$leastFreeDisk"
}

# # Function to move the directory to a specified disk
# moveDirectory() {
#     local sourceDiskName="$1"
#     local sourceDisk="/mnt/$sourceDiskName"
#     local destinationDisk="$2"
#     local moverMode="$3"  # Directory selection strategy: largest, smallest, random

#     logMessage "debug" "Move directory function called for $sourceDisk to $destinationDisk using strategy: $moverMode"

#     # Function to check if a directory exists in the source path
#     checkDirectoryExists() {
#         echo "sourceDir=$1"
#         local sourceDir="$1"
#         [ -n "$(find "$sourceDir" -mindepth 1 -print -quit 2>/dev/null)" ]
#     }

#     # Attempt to find the available source directories based on the strategy
#     local potentialSourceDirs=()
#     for potentialSourceDir in "${sourceDirs[@]}"; do
#         # echo "potentialSourceDirs=(${potentialSourceDir/disk\#/$sourceDiskName}"
#         if checkDirectoryExists "${potentialSourceDir/disk\#/$sourceDiskName}"; then
#             potentialSourceDirs+=("${potentialSourceDir/disk\#/$sourceDiskName}")
#         fi
#     done

#     # If no source directories are found, trigger the error handler
#     if [ ${#potentialSourceDirs[@]} -eq 0 ]; then
#         logMessage "error" "No source directories found for $sourceDisk"
#         return
#     fi

#     # Select the directory based on the strategy
#     local selectedDirectory=""
#     case "$moverMode" in
#         "largest")
#             for potentialSourceDir in "${potentialSourceDirs[@]}"; do
#                 largestSubdir=$(du -h "$potentialSourceDir"/* | sort -rh | head -n 1 | cut -f2-)
#                 [ -n "$largestSubdir" ] && selectedDirectory="$largestSubdir" && break
#             done
#             ;;
#         "smallest")
#             for potentialSourceDir in "${potentialSourceDirs[@]}"; do
#                 smallestSubdir=$(du -h "$potentialSourceDir"/* | sort -h | head -n 1 | cut -f2-)
#                 [ -n "$smallestSubdir" ] && selectedDirectory="$smallestSubdir" && break
#             done
#             ;;
#         "random")
#             selectedSourceDir=${potentialSourceDirs[RANDOM % ${#potentialSourceDirs[@]}]}
#             selectedDirectory=$(du -h "$selectedSourceDir"/* | shuf -n 1 | cut -f2-)
#             ;;
#         *)
#             logMessage "error" "Invalid directory selection strategy: $moverMode"
#             return
#             ;;
#     esac

#     # Remove any consecutive slashes in the selected directory
#     selectedDirectory=$(echo "$selectedDirectory" | sed 's#//*#/#g')

#     logMessage "debug" "Selected directory: $selectedDirectory"

#     # Get the destination directory on the new disk
#     local destinationDir="${destinationDisk}/${selectedDirectory#${sourceDisk}/}"

#     logMessage "debug" "Destination directory set to: $destinationDir"
    
#     # Log the move in simulation mode or perform the actual move
#     if $simulationMode; then
#         # Run rsync in dry-run mode and capture the output
#         dryRunOutput=$(rsync -av --dry-run --remove-source-files "$selectedDirectory" "$destinationDir" 2>&1)

#         # Log the rsync dry-run output
#         # logMessage "info" "Rsync Dry-Run Output (Simulation Mode):"
#         logMessage "info" "$dryRunOutput"
        
#         logMessage "info" "[SIMULATED] Moved $selectedDirectory to $destinationDir"
#     else
#         # Perform the actual move
#         rsync -a --remove-source-files "$selectedDirectory" "$destinationDir"

#         # Check the exit status of the rsync command
#         if [ $? -eq 0 ]; then
#             logMessage "info" "Moved $selectedDirectory to $destinationDir"

#             # Remove empty directories from the source
#             find "$selectedDirectory" -type d -empty -delete
#         else
#             logMessage "error" "Failed to move $selectedDirectory to $destinationDir"
#         fi
#     fi
# }

# Function to move the directory to a specified disk
# moveDirectory() {
#     local sourceDiskName="$1"
#     local sourceDisk="/mnt/$sourceDiskName"
#     local destinationDisk="$2"
#     local moverMode="$3"  # Directory selection strategy: largest, smallest, random

#     logMessage "debug" "Move directory function called for $sourceDisk to $destinationDisk using strategy: $moverMode"

#     # Function to check if a directory exists in the source path
#     checkDirectoryExists() {
#         local sourceDir="$1"
#         [ -n "$(find "$sourceDir" -mindepth 1 -print -quit 2>/dev/null)" ]
#     }

#     # Attempt to find the available source directories based on the strategy
#     local potentialSourceDirs=()
#     for potentialSourceDir in "${sourceDirs[@]}"; do
#         if checkDirectoryExists "${potentialSourceDir/disk\#/$sourceDiskName}"; then
#             potentialSourceDirs+=("${potentialSourceDir/disk\#/$sourceDiskName}")
#         fi
#     done

#     # If no source directories are found, trigger the error handler
#     if [ ${#potentialSourceDirs[@]} -eq 0 ]; then
#         logMessage "error" "No source directories found for $sourceDisk"
#         return
#     fi

#     # Select the directory based on the strategy
#     local selectedDirectory=""
#     case "$moverMode" in
#         "largest")
#             for potentialSourceDir in "${potentialSourceDirs[@]}"; do
#                 largestSubdir=$(du -h "$potentialSourceDir"/* | sort -rh | head -n 1 | cut -f2-)
#                 [ -n "$largestSubdir" ] && selectedDirectory="$largestSubdir" && break
#             done
#             ;;
#         "smallest")
#             for potentialSourceDir in "${potentialSourceDirs[@]}"; do
#                 smallestSubdir=$(du -h "$potentialSourceDir"/* | sort -h | head -n 1 | cut -f2-)
#                 [ -n "$smallestSubdir" ] && selectedDirectory="$smallestSubdir" && break
#             done
#             ;;
#         "random")
#             selectedSourceDir=${potentialSourceDirs[RANDOM % ${#potentialSourceDirs[@]}]}
#             selectedDirectory=$(du -h "$selectedSourceDir"/* | shuf -n 1 | cut -f2-)
#             ;;
#         *)
#             logMessage "error" "Invalid directory selection strategy: $moverMode"
#             return
#             ;;
#     esac

#     # Remove any consecutive slashes in the selected directory
#     selectedDirectory=$(echo "$selectedDirectory" | sed 's#//*#/#g')

#     logMessage "debug" "Selected directory: $selectedDirectory"

#     # Get the destination directory on the new disk
#     local destinationDir="${destinationDisk}/${selectedDirectory#${sourceDisk}/}"

#     logMessage "debug" "Destination directory set to: $destinationDir"
    
#     # Log the move in simulation mode or perform the actual move
#     if $simulationMode; then
#         # Run rsync in dry-run mode and capture the output
#         dryRunOutput=$(rsync -av --dry-run --remove-source-files "$selectedDirectory" "$destinationDir" 2>&1)

#         # Log the rsync dry-run output
#         # logMessage "info" "Rsync Dry-Run Output (Simulation Mode):"
#         logMessage "info" "$dryRunOutput"
        
#         logMessage "info" "[SIMULATED] Moved $selectedDirectory to $destinationDir"
#     else
#         # Perform the actual move
#         rsync -a --remove-source-files "$selectedDirectory" "$destinationDir"

#         # Check the exit status of the rsync command
#         if [ $? -eq 0 ]; then
#             logMessage "info" "Moved $selectedDirectory to $destinationDir"

#             # Remove empty directories from the source
#             find "$selectedDirectory" -type d -empty -delete
#         else
#             logMessage "error" "Failed to move $selectedDirectory to $destinationDir"
#         fi
#     fi
# }



# Function to move directories from a source disk to a destination disk
# moveDirectories() {
#     local sourceDisk="$1"
#     local destinationDisk="$2"

#     # Function to get the available directories on the source disk
#     getAvailableDirectories() {
#         find "$sourceDisk" -maxdepth 1 -mindepth 1 -type d
#     }

#     # Get the list of available directories on the source disk
#     local availableDirectories=($(getAvailableDirectories))

#     # If there are no available directories, return
#     if [ ${#availableDirectories[@]} -eq 0 ]; then
#         logMessage "info" "No directories found on $sourceDisk for transfer."
#         return
#     fi

#     # Create a temporary file to store the list of files to be transferred
#     local fileList=$(mktemp)

#     # Calculate the total size of directories to be transferred
#     local totalSize=0
#     for dir in "${availableDirectories[@]}"; do
#         du -s "$dir" | awk '{print $1}' >> "$fileList"
#         totalSize=$((totalSize + $(du -s "$dir" | awk '{print $1}')))
#     done

#     # Function to check if there is enough space on the destination disk
#     checkDestinationSpace() {
#         local requiredSpace=$1
#         local availableSpace=$(getFreeSpace "$destinationDisk")
#         [ "$availableSpace" -ge "$requiredSpace" ]
#     }

#     # If there is not enough space on the destination disk, log an error
#     if ! checkDestinationSpace "$totalSize"; then
#         logMessage "error" "Not enough space on $destinationDisk to transfer directories from $sourceDisk."
#         rm -f "$fileList"  # Remove the temporary file
#         return
#     fi

#     # Perform the transfer
#     local transferredSize=0
#     local transferredCount=0
#     while [ "$transferredSize" -lt "$totalSize" ] && [ "$transferredCount" -lt "$fileTransferLimit" ]; do
#         local dir="${availableDirectories[$transferredCount]}"
#         moveDirectory "$sourceDisk" "$destinationDisk" "$moverMode" "$dir" &
#         transferredSize=$((transferredSize + $(du -s "$dir" | awk '{print $1}')))
#         transferredCount=$((transferredCount + 1))
#     done

#     # Wait for background transfers to complete
#     wait

#     # Remove the temporary file
#     rm -f "$fileList"
# }

# Temporary file to store the list of directories to be transferred
fileList="$scriptDir/temp_file.txt"

# Simulation file to store the list of directories and their calculated sizes during simulation mode
simulationFile="$scriptDir/movarr_simulation.txt"
fileTransferLimit=4

# Function to calculate the total size of directories in the file list
calculateTotalSize() {
    awk '{total+=$1} END{print total}' "$fileList"
}

# Function to format simulation entry
formatSimulationEntry() {
    local size="$1"
    local sourceDir="$2"
    local destDisk="$3"

    printf "%-5s %-30s %-20s\n" "$size" "$sourceDir" "$destDisk"
}

# Function to set destination disk for simulation entry
setDestinationDisk() {
    local diskName="$1"
    echo "# $diskName" >> "$simulationFile"
}

# Function to transfer directories
transferDirectories() {
    local sourceDisks=("$@")

    # Determine total space available on destination disks
    local totalAvailableSpace=0
    for destDisk in "${destinationDisks[@]}"; do
        if shouldExcludeTransfer "$(basename "$destDisk")"; then
            logMessage "info" "Skipping excluded destination disk: $(basename "$destDisk")"
            continue
        fi
        local freeSpace=$(df -BG "$destDisk" | awk 'NR==2 {print $4}' | sed 's/G//')
        totalAvailableSpace=$((totalAvailableSpace + freeSpace))
    done

    # Generate list of files to transfer
    local filesToTransfer=()
    for sourceDisk in "${sourceDisks[@]}"; do
        while IFS= read -r -d $'\0' file; do
            filesToTransfer+=("$file")
        done < <(find "$sourceDisk" -type f -print0)
    done

    local totalFileSize=0
    local destDiskIndex=0
    local tmpFile="$scriptDir/simulationFile.txt"

    # Remove existing simulation file
    rm -f "$tmpFile"

    # Generate simulation file
    for file in "${filesToTransfer[@]}"; do
        local fileSize=$(du -BG "$file" | awk '{print $1}' | sed 's/G//')
        totalFileSize=$((totalFileSize + fileSize))

        if [ "$totalFileSize" -gt "$totalAvailableSpace" ]; then
            logMessage "error" "Not enough space on destination disks to transfer all files."
            exit 1
        fi

        local destDisk="${destinationDisks[$destDiskIndex]}"
        echo -e "Source: $file\nDestination: $destDisk" >> "$tmpFile"

        destDiskIndex=$(( (destDiskIndex + 1) % ${#destinationDisks[@]} ))
    done

    if [ "$simulationMode" = true ]; then
        logMessage "info" "Simulation mode is enabled. Exiting after generating simulation file."
        exit 0
    fi

    # Transfer files
    for file in "${filesToTransfer[@]}"; do
        local destDisk="${destinationDisks[$destDiskIndex]}"

        if ! rsync -Pa "$file" "$destDisk"; then
            logMessage "error" "Failed to transfer $file to $destDisk"
        fi

        destDiskIndex=$(( (destDiskIndex + 1) % ${#destinationDisks[@]} ))
    done

    logMessage "info" "File transfer completed."
}

# Function to determine the destination disk for each directory based on available space
determineDestinations() {
    local sourceDisk="$1"

    for directory in "${sourceDirs[@]}"; do
        # Skip if the directory does not exist on the source disk
        if ! checkDirectoryExists "${directory/disk\#/$sourceDisk}"; then
            continue
        fi

        # Find the destination disk with the least free space greater than the destination limit
        destDisk=$(findLeastFreeDisk "$destinationFreeLimit")

        # Calculate the size of the directory
        dirSize=$(du -s "${directory/disk\#/$sourceDisk}" | cut -f1)

        # Append the directory, size, and destination disk to the file list
        echo "$dirSize $directory $destDisk" >> "$fileList"
    done
}

# Function to add a header with date and time to the log file
addHeader() {
    echo -e "==== Movarr Results for $(date) ====\n" >>"$logFile"
}

# Function to add a footer with total data moved from and to each disk
addFooter() {
    local endTime=$(date +%s)
    local elapsedTime=$((endTime - startTime))

    local elapsedHours=$((elapsedTime / 3600))
    local elapsedMinutes=$(( (elapsedTime % 3600) / 60 ))
    local elapsedSeconds=$((elapsedTime % 60))

    echo "===== Summary =====" >> "$logFile"

    local totalDataMoved=""
    local totalDataAdded=""
    local totalDataRemoved=""

    for diskPath in "${diskPaths[@]}"; do
        diskName=$(basename "$diskPath")

        movedData=$(du -sh "$disk" 2>/dev/null || echo "0M")
        totalDataMoved+="Disk$diskName: $movedData moved to "

        addedData=$(du -sh "$addedDataPath/$diskName" 2>/dev/null || echo "0M")
        totalDataAdded+="Disk$diskName: $addedData, "

        removedData=$(du -sh "$removedDataPath/$diskName" 2>/dev/null || echo "0M")
        totalDataRemoved+="Disk$diskName: $removedData, "
    done

    # Remove trailing commas
    totalDataAdded="${totalDataAdded%,*}"
    totalDataRemoved="${totalDataRemoved%,*}"

    logMessage "info" "$totalDataMoved"
    logMessage "info" "$totalDataAdded moved from"
    logMessage "info" "$totalDataRemoved"
    logMessage "info" "---------------------------"
    logMessage "info" "Total Data Moved: $totalDataMoved"
    logMessage "info" "Script Execution Time: ${elapsedHours}h ${elapsedMinutes}m ${elapsedSeconds}s"
}

# Function to roll over the log file based on the number of files and delete older log files
rollOverLogs() {
    local logDir=$(dirname "$logFile")
    local logFileName=$(basename "$logFile")
    local logFileWildcard="$logFilePrefix*.txt"

    # Ensure the logs directory exists
    mkdir -p "$logDir"

    # Create a new header for the new log file
    addHeader

    # Get the number of existing log files
    local fileCount=$(find "$logDir" -maxdepth 1 -type f -name "$logFileWildcard" | wc -l)

    # Calculate the number of excess files
    local excessFiles=$((fileCount - maxRollovers))

    # Remove older log files if there are excess files
    if [ "$excessFiles" -gt 0 ]; then
        # Sort files by modification time (oldest first) and delete excess files
        find "$logDir" -maxdepth 1 -type f -name "$logFileWildcard" | \
        xargs ls -lt | \
        tail -n "$excessFiles" | \
        awk '{print $NF}' | \
        xargs rm
    fi
}

# Main loop
# while :; do
#     moveNeeded=false

#     # Roll over the log file
#     rollOverLogs

#     # Iterate over each disk
#     for diskPath in "${diskPaths[@]}"; do
#         diskName=$(basename "$diskPath")

#         # Exclude directories that do not match the format "disk#"
#         if [[ ! $diskName =~ ^disk[0-9]+$ ]]; then
#             logMessage "warn" "Skipping invalid disk directory: $diskName"
#             continue
#         fi

#         # Check if the disk should be excluded from searching
#         if shouldExcludeSearch "$diskName"; then
#             continue
#         fi

#         freeSpace=$(getFreeSpace "$diskPath")

#         # Check if free space is less than the source limit
#         if [[ $freeSpace -lt $sourceFreeLimit ]]; then
#             moveNeeded=true
#             # Find the disk with the least free space greater than the destination limit
#             targetDisk=$(findLeastFreeDisk "$destinationFreeLimit")

#             # Move the first directory to the target disk
#             if [[ -n $targetDisk ]]; then
#                 # Run moveDirectory in the background if backgroundTasks is enabled
#                 if [ "$backgroundTasks" = "true" ]; then
#                     moveDirectory "$diskName" "$targetDisk" "$moverMode" &
#                 else
#                     moveDirectory "$diskName" "$targetDisk" "$moverMode"
#                 fi
#             fi
#         fi
#     done

#     # Wait for all background jobs to finish if backgroundTasks is enabled
#     if [ "$backgroundTasks" = "true" ]; then
#         wait
#     fi

#     # Exit the loop if no move is needed for any disk
#     if ! $moveNeeded; then
#         break
#     fi
# done

# moveNeeded=true
# while $moveNeeded; do
#     moveNeeded=false

#     for diskPath in $(echo "${diskPaths[@]}" | tr ' ' '\n' | sort); do
#         diskName=$(basename "$diskPath")

#         # Exclude directories that do not match the format "disk#"
#         if [[ ! $diskName =~ ^disk[0-9]+$ ]]; then
#             logMessage "warn" "Skipping invalid disk directory: $diskName"
#             continue
#         fi

#         # Check if the disk should be excluded from searching
#         if shouldExcludeSearch "$diskName"; then
#             continue
#         fi

#         freeSpace=$(getFreeSpace "$diskPath")

#         # Check if free space is less than the source limit
#         while [ $freeSpace -lt $sourceFreeLimit ]; do
#             moveNeeded=true
#             # Find the disk with the least free space greater than the destination limit
#             targetDisk=$(findLeastFreeDisk "$destinationFreeLimit")

#             # Move files from the current disk to the target disk
#             if [[ -n $targetDisk ]]; then
#                 # Run moveDirectory in the background if backgroundTasks is enabled
#                 if [ "$backgroundTasks" = "true" ]; then
#                     moveDirectory "$diskName" "$targetDisk" "$moverMode" &
#                 else
#                     moveDirectory "$diskName" "$targetDisk" "$moverMode"
#                 fi
#             fi

#             # Wait for all background jobs to finish if backgroundTasks is enabled
#             if [ "$backgroundTasks" = "true" ]; then
#                 wait
#             fi

#             # Update free space for the current disk
#             freeSpace=$(getFreeSpace "$diskPath")
#         done
#     done
# done

# # Add footer for the current log file
# addFooter

# logMessage "info" "Movarr is done."

# Main loop
while :; do
    moveNeeded=false

    # Roll over the log file
    rollOverLogs

    # Iterate over each source disk
    for sourceDisk in $(echo "${diskPaths[@]}" | tr ' ' '\n' | sort); do
        sourceDiskName=$(basename "$sourceDisk")

        # Exclude directories that do not match the format "disk#"
        if [[ ! $sourceDiskName =~ ^disk[0-9]+$ ]]; then
            logMessage "warn" "Skipping invalid source disk directory: $sourceDiskName"
            continue
        fi

        # Check if the source disk should be excluded from searching
        if shouldExcludeSearch "$sourceDiskName"; then
            continue
        fi

        freeSpace=$(getFreeSpace "$sourceDisk")

        # Check if free space is less than the source limit
        while [ "$freeSpace" -lt "$sourceFreeLimit" ]; do
            moveNeeded=true

            # Find the next destination disk
            destinationDisk=$(findLeastFreeDisk "$destinationFreeLimit")

            # Move directories from the source disk to the destination disk
            if [ -n "$destinationDisk" ]; then
                moveDirectories "$sourceDisk" "$destinationDisk"
            else
                logMessage "error" "No destination disk found for $sourceDisk. Exiting."
                exit 1
            fi

            # Update free space for the source disk
            freeSpace=$(getFreeSpace "$sourceDisk")
        done
    done

    # Exit the loop if no move is needed for any disk
    if ! $moveNeeded; then
        break
    fi
done


# Main loop to transfer directories from source to destination disks
while :; do
    # ... (Previous code to find source and destination disks)

    # Determine the destination for each directory based on available space
    determineDestinations "$sourceDisk"

    # Check if there are directories to transfer
    if [ -s "$fileList" ]; then
        # Calculate the total size of directories to be transferred
        totalSize=$(calculateTotalSize)

        # Save simulation file and exit if simulation mode is enabled
        if $simulationMode; then
            # Delete existing simulation files before creating a new one
            rm -f "$simulationFile"
            cp "$fileList" "$simulationFile"
            logMessage "info" "Simulation file created: $simulationFile. Exiting simulation mode."
            exit 0
        fi

        # Transfer directories from source to destination disks
        transferDirectories "$sourceDisk" "$destinationDisk"

        # Check if all directories were transferred
        if [ "$(wc -l < "$fileList")" -eq 0 ]; then
            logMessage "info" "All directories transferred. Exiting loop."
            break
        fi
    else
        logMessage "info" "No directories to transfer. Exiting loop."
        break
    fi
done

# Add footer for the current log file
addFooter

logMessage "info" "Movarr is done."