#!/bin/bash

# movarr.sh - Script to transfer directories from source disks to target disks
# based on available space, with optional simulation mode.

# Set start time
startTime=$(date +%s)

# Configuration variables
dryRun=false
logLevel="info"
# logFileNameTimestamp=false
maxLogSize=30
maxLogRollovers=3
diskPath="/mnt"
diskRegex="disk[0-9]{1,2}"
includeDisks=()
excludeDisks=()
excludeSourceDisks=()
excludeTargetDisks=()
rootFolders=("/data/media/movies")
minFreeDiskSpace="20480 MB"
maxSourceDiskFreeSpace="20480 MB"
minTargetDiskFreeSpace="20480 MB"
backgroundTasks=false
fileTransferLimit=4
moverMode="largest"
notificationType="none"
notifyEmail=""

scriptDir="$(cd -- "$(dirname "$0")" >/dev/null 2>&1; pwd -P)"
configFileName="config.ini"
configFilePath="$scriptDir/$configFileName"
logFileName="movarr.log"
logFilePath="$scriptDir/logs/$logFileName"
dryRunFileName="simulation.txt"
dryRunFilePath="$scriptDir/$dryRunFileName"
fileListFileName="tmp_file.txt"
fileListFilePath="$scriptDir/$fileListFileName"

# timestamp=$(date +"%Y%m%d_%H%M%S")

# Function to log messages
logMessage() {
    local logLevels="$1"
    shift
    local logMessage="$@"
    local lineNumber="${BASH_LINENO[0]}"

    # Check if logFilePath is set
    if [ -z "$logFilePath" ]; then
        echo "$(date +"%Y-%m-%d %H:%M:%S") [ERROR] [$lineNumber] logFilePath is not set."
        return 1
    fi

    # Check if log file exceeds maxLogSize
    if [ -f "$logFilePath" ]; then
        logFileSize=$(du -m "$logFilePath" | cut -f1)
        if [ "$logFileSize" -ge "$maxLogSize" ]; then
            # Rotate log files
            for ((i = maxLogRollovers - 1; i >= 0; i--)); do
                if [ -f "$scriptDir/logs/movarr.$i.log" ]; then
                    mv "$scriptDir/logs/movarr.$i.log" "$scriptDir/logs/movarr.$((i + 1)).log"
                fi
            done
            mv "$logFilePath" "$scriptDir/logs/movarr.0.log"
            touch "$logFilePath"
        fi
    fi

    IFS=',' read -ra levels <<< "$logLevels"
    for logLevel in "${levels[@]}"; do
        case "$logLevel" in
            "trace" | "debug")
                # Print debug messages to the console for troubleshooting
                echo "$(date +"%Y-%m-%d %H:%M:%S") [$logLevel] [$lineNumber] $logMessage"
                ;;
            "info" | "warn" | "error")
                # Log messages to the specified log file
                echo "$(date +"%Y-%m-%d %H:%M:%S") [$logLevel] $logMessage" >>"$logFilePath"

                # Send notifications based on the notificationType
                if [ "$notificationType" != "none" ]; then
                    case "$notificationType" in
                        "email")
                            # Send email notification (assuming mail command is configured)
                            echo "$logMessage" | mail -s "Movarr Notification - $logLevel" "$notifyEmail"
                            ;;
                        "unraid")
                            # Use Unraid's notification system
                            case "$logLevel" in
                                "info")
                                    /usr/local/emhttp/webGui/scripts/notify -i normal -s "$logMessage"
                                    ;;
                                "warn")
                                    /usr/local/emhttp/webGui/scripts/notify -i warning -s "$logMessage"
                                    ;;
                                "error")
                                    /usr/local/emhttp/webGui/scripts/notify -i alert -s "$logMessage"
                                    ;;
                            esac
                            ;;
                    esac
                fi
                ;;
            *)
                echo "$(date +"%Y-%m-%d %H:%M:%S") [ERROR]: Invalid log level '$logLevel'" >>"$logFilePath"
                ;;
        esac
    done
}

# Load configuration file
if [ -f "$configFilePath" ]; then
    . "$configFilePath"
else
    logMessage "error" "Configuration file $configFileName not found at $configFilePath."
    exit 1
fi

# if [ "$logFileTimestamp" = true ]; then
#     baseName="${logFileName%.*}"
#     extension="${logFileName##*.}"
#     logFileName="${baseName}_${timestamp}.${extension}"
# fi

# Function to initialize logs and handle log rollover
initializeLogs() {
    mkdir -p "$scriptDir/logs"

    # Remove old log files if they exceed maxLogRollovers
    # logFiles=("$scriptDir/logs/movarr."*.log)
    logFiles=("$scriptDir/logs/movarr"*.log)
    logCount=${#logFiles[@]}
    if [ "$logCount" -gt "$maxLogRollovers" ]; then
        filesToRemove=$((logCount - maxLogRollovers))
        for ((i = 0; i < filesToRemove; i++)); do
            rm -f "${logFiles[$i]}"
        done
    fi

    # Create a new log file if not present
    if [ ! -f "$logFilePath" ]; then
        touch "$logFilePath"
        
        # Set permissions
        chmod 644 "$logFilePath"
    fi

    # Add header to the log file
    addHeader "$logFilePath"
}

validateDiskSpace() {  # NO LOGGING ALLOWED IN THIS FUNCTION!
    local spaceValue="$1"
    local spaceName="$2"
    local errors="$3"

    if [[ "$spaceValue" =~ ^([0-9]+)[[:space:]]*(MB|GB)?$ ]]; then
        size=${BASH_REMATCH[1]}
        unit=${BASH_REMATCH[2]}
        if [ -z "$unit" ]; then
            unit="GB"
        fi
        if [ "$unit" == "GB" ]; then
            spaceValue=$((size * 1024))
        else
            spaceValue=$size
        fi
    else
        ((errors++))
    fi

    echo "$spaceValue"
}

# Function to validate configuration
validateConfiguration() {
    local errors=0

    logMessage "debug" "Validating configuration..."

    # Validate dryRun (should be true or false)
    logMessage "debug" "dryRun: $dryRun"
    if [ "$dryRun" != "true" ] && [ "$dryRun" != "false" ]; then
        logMessage "error" "Invalid value for 'dryRun'. It should be true or false."
        ((errors++))
    fi

    # Validate logLevel (should be debug, info, warn, or error)
    logMessage "debug" "logLevel: $logLevel"
    if [ "$logLevel" != "trace" ] && [ "$logLevel" != "debug" ] && [ "$logLevel" != "info" ] && [ "$logLevel" != "warn" ] && [ "$logLevel" != "error" ]; then
        logMessage "error" "Invalid value for 'logLevel'. It should be one of: trace, debug, info, warn, error."
        ((errors++))
    fi

    # Validate logFileNameTimestamp (should be true or false)
    # logMessage "debug" "logFileNameTimestamp: $logFileNameTimestamp"
    # if [ "$logFileNameTimestamp" != "true" ] && [ "$logFileNameTimestamp" != "false" ]; then
    #     logMessage "error" "Invalid value for 'logFileNameTimestamp'. It should be true or false."
    #     ((errors++))
    # fi

    # Validate maxLogSize (should be a positive integer)
    logMessage "debug" "maxLogSize: $maxLogSize"
    if ! [[ "$maxLogSize" =~ ^[1-9][0-9]*$ ]]; then
        logMessage "error" "Invalid value for 'maxLogSize'. It should be a positive integer."
        ((errors++))
    fi

    # Validate maxLogRollovers (should be a positive integer)
    logMessage "debug" "maxLogRollovers: $maxLogRollovers"
    if ! [[ "$maxLogRollovers" =~ ^[1-9][0-9]*$ ]]; then
        logMessage "error" "Invalid value for 'maxLogRollovers'. It should be a positive integer."
        ((errors++))
    fi

    # Validate diskPath (should be a valid directory)
    logMessage "debug" "diskPath: $diskPath"
    if [ ! -d "$diskPath" ]; then
        logMessage "error" "Invalid value for 'diskPath'. It should be a valid directory."
        ((errors++))
    else
        # Strip trailing slashes from diskPath
        diskPath=$(echo "$diskPath" | sed 's:/*$::')
    fi

    # Validate diskRegex (should be a valid regex pattern)
    logMessage "debug" "diskRegex: $diskRegex"
    if [ -n "$diskRegex" ]; then
        matchingDisks=()
        for disk in $(ls "$diskPath"); do
            if [[ "$disk" =~ $diskRegex ]]; then
                matchingDisks+=("$disk")
            fi
        done

        if [ ${#matchingDisks[@]} -eq 0 ]; then
            logMessage "error" "No disks in '$diskPath' match the regex pattern '$diskRegex'."
            ((errors++))
        else
            # logMessage "debug" "Disks matching '$diskRegex' in '$diskPath': ${matchingDisks[@]}"
            activeDisks=("${matchingDisks[@]}")
        fi
    fi

    # Validate includeDisks (should be an array of disk names)
    logMessage "debug" "includeDisks: ${includeDisks[@]}"
    if [ ${#includeDisks[@]} -ne 0 ]; then
        for disk in "${includeDisks[@]}"; do
            logMessage "debug" "Validating includeDisk: $disk"
            if [ -d "$diskPath/$disk" ]; then
                logMessage "debug" "Disk '$disk' exists in '$diskPath'"
                # Check if the disk is already in activeDisks
                if [[ ! " ${activeDisks[@]} " =~ " $disk " ]]; then
                    activeDisks+=("$disk")
                else
                    logMessage "debug" "Disk '$disk' is already in activeDisks"
                fi
            else
                logMessage "error" "Disk '$disk' in 'includeDisks' does not exist in '$diskPath'."
                ((errors++))
            fi
        done
    fi

    # Validate excludeDisks (should be an array of disk names)
    logMessage "debug" "excludeDisks: ${excludeDisks[@]}"
    if [ ${#excludeDisks[@]} -ne 0 ]; then
        for disk in "${excludeDisks[@]}"; do
            logMessage "debug" "Validating excludeDisk: $disk"
            found=false

            for activeDisk in "${activeDisks[@]}"; do
                if [ "$activeDisk" == "$disk" ]; then
                    excludedDisks+=("$disk")
                    found=true
                    break
                fi
            done
            if [ "$found" = false ]; then
                logMessage "error" "Disk '$disk' in 'excludeDisks' does not exist in 'activeDisks'."
                ((errors++))
            fi
        done
    fi

    # Validate excludeSourceDisks (should be an array of disk names)
    logMessage "debug" "excludeSourceDisks: ${excludeSourceDisks[@]}"
    excludedSourceDisks=()
    if [ ${#excludeSourceDisks[@]} -ne 0 ]; then
        for disk in "${excludeSourceDisks[@]}"; do
            logMessage "debug" "Validating excludeSourceDisk: $disk"
            found=false
            for activeDisk in "${activeDisks[@]}"; do
                if [ "$activeDisk" == "$disk" ]; then
                    excludedSourceDisks+=("$disk")
                    found=true
                    break
                fi
            done
            if [ "$found" = false ]; then
                logMessage "error" "Disk '$disk' in 'excludeSourceDisks' does not exist in 'activeDisks'."
                ((errors++))
            fi
        done
    fi

    # Validate excludeTargetDisks (should be an array of disk names)
    logMessage "debug" "excludeTargetDisks: ${excludeTargetDisks[@]}"
    excludedTargetDisks=()
    if [ ${#excludeTargetDisks[@]} -ne 0 ]; then
        for disk in "${excludeTargetDisks[@]}"; do
            logMessage "debug" "Validating excludeTargetDisk: $disk"
            found=false
            for activeDisk in "${activeDisks[@]}"; do
                if [ "$activeDisk" == "$disk" ]; then
                    excludedTargetDisks+=("$disk")
                    found=true
                    break
                fi
            done
            if [ "$found" = false ]; then
                logMessage "error" "Disk '$disk' in 'excludeTargetDisks' does not exist in 'activeDisks'."
                ((errors++))
            fi
        done
    fi

    # Validate rootFolders (should be an array of directories)
    logMessage "debug" "rootFolders: ${rootFolders[@]}"
    if [ ${#rootFolders[@]} -ne 0 ]; then
        for i in "${!rootFolders[@]}"; do
            rootFolderPath="${rootFolders[$i]}"
            logMessage "debug" "Validating rootFolder: $rootFolderPath"
            rootFolderPathExists=false
            for disk in "${activeDisks[@]}"; do
                # Skip excludedSourceDisks
                if [[ " ${excludedSourceDisks[@]} " =~ " $disk " ]]; then
                    logMessage "debug" "Skipping excluded source disk: $disk"
                    continue
                fi
                # Remove trailing slashes from disk and path
                disk=$(echo "$disk" | sed 's:/*$::')
                strippedRootFolderPath=$(echo "$rootFolderPath" | sed 's:^/*::')
                logMessage "debug" "Checking if $diskPath/$disk/$strippedRootFolderPath exists"
                if [ -d "$diskPath/$disk/$strippedRootFolderPath" ]; then
                    logMessage "debug" "Directory $diskPath/$disk/$strippedRootFolderPath exists"
                    rootFolderPathExists=true
                    break
                else
                    logMessage "debug" "Directory $diskPath/$disk/$strippedRootFolderPath does not exist"
                fi
            done
            if [ "$rootFolderPathExists" = false ]; then
                logMessage "error" "Directory '$rootFolderPath' in 'rootFolders' does not exist in any of the source disks."
                ((errors++))
            else
                # Update the rootFolders array with the stripped version
                rootFolders[$i]="$strippedRootFolderPath"
            fi
        done
    fi

    # Validate disk space values
    minFreeDiskSpace=$(validateDiskSpace "$minFreeDiskSpace" "minFreeDiskSpace" "$errors")
    maxSourceDiskFreeSpace=$(validateDiskSpace "$maxSourceDiskFreeSpace" "maxSourceDiskFreeSpace" "$errors")
    minTargetDiskFreeSpace=$(validateDiskSpace "$minTargetDiskFreeSpace" "minTargetDiskFreeSpace" "$errors")

    echo "<<<" $minFreeDiskSpace ">>>";
    echo "<<<" $maxSourceDiskFreeSpace ">>>";
    echo "<<<" $minTargetDiskFreeSpace ">>>";
    
    logMessage "debug" "minFreeDiskSpace=$(formatSpace $minFreeDiskSpace), maxSourceDiskFreeSpace=$(formatSpace $maxSourceDiskFreeSpace), minTargetDiskFreeSpace=$(formatSpace $minTargetDiskFreeSpace)"

    # Validate backgroundTasks (should be true or false)
    logMessage "debug" "backgroundTasks: $backgroundTasks"
    if [ "$backgroundTasks" != "true" ] && [ "$backgroundTasks" != "false" ]; then
        logMessage "error" "Invalid value for 'backgroundTasks'. It should be true or false."
        ((errors++))
    fi

    # Validate fileTransferLimit (should be a positive integer and not exceed 10)
    logMessage "debug" "fileTransferLimit: $fileTransferLimit"
    if ! [[ "$fileTransferLimit" =~ ^[1-9][0-9]*$ ]] || [ "$fileTransferLimit" -gt 10 ]; then
        logMessage "error" "Invalid value for 'fileTransferLimit'. It should be a positive integer between 1 and 10."
        ((errors++))
    fi

    # Validate moverMode (should be one of largest, smallest, oldest, newest)
    logMessage "debug" "moverMode: $moverMode"
    if [ "$moverMode" != "largest" ] && [ "$moverMode" != "smallest" ] && [ "$moverMode" != "oldest" ] && [ "$moverMode" != "newest" ]; then
        logMessage "error" "Invalid value for 'moverMode'. It should be one of: largest, smallest, oldest, newest."
        ((errors++))
    fi

    # Validate notificationType (should be one of none, email, or pushbullet)
    logMessage "debug" "notificationType: $notificationType"
    if [ "$notificationType" != "none" ] && [ "$notificationType" != "unraid" ] && [ "$notificationType" != "email" ]; then
        logMessage "error" "Invalid value for 'notificationType'. It should be one of: none, unraid, email."
        ((errors++))
    fi

    # Validate notifyEmail (should be a valid email address)
    logMessage "debug" "notifyEmail: $notifyEmail"
    if [ "$notificationType" = "email" ] && ! [[ "$notifyEmail" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        logMessage "error" "Invalid value for 'notifyEmail'. It should be a valid email address."
        ((errors++))
    fi

    if [ "$errors" -gt 0 ]; then
        logMessage "error" "Configuration validation failed with $errors errors."
        exit 1
    fi

    # Sort activeDisks to ensure disk1 precedes disk10
    activeDisks=($(printf "%s\n" "${activeDisks[@]}" | sort -V))

    logMessage "info" "Configuration validation completed successfully."
}

# Function to check if an array contains a specific disk
arrayContainsDisk() {
    local array=("$@")
    local seeking=${array[-1]}
    unset array[-1]
    for element in "${array[@]}"; do
        if [[ "$element" == "$seeking" ]]; then
            return 0
        fi
    done
    return 1
}

# Function to get the free space of a disk in MB
getFreeSpace() {
    df -m "$diskPath/$1" | awk 'NR==2 {print $4}'
}

convertThreshold() {
    local disk="$1"
    local threshold="$2"

    # Get total and available space on the disk in bytes
    local total_space=$(df --output=size -B1 "$disk" | tail -1)
    local available_space=$(df --output=avail -B1 "$disk" | tail -1)

    # If threshold is in percentage format (e.g., "5%"), calculate equivalent bytes
    if [[ "$threshold" =~ ^[0-9]+%$ ]]; then
        local percent=${threshold%\%}  # Remove % sign
        echo $((total_space * percent / 100))
    elif [[ "$threshold" =~ ^[0-9]+(GB|G)$ ]]; then
        echo $(( ${threshold%GB} * 1024 * 1024 * 1024 ))
    elif [[ "$threshold" =~ ^[0-9]+(MB|M)$ ]]; then
        echo $(( ${threshold%MB} * 1024 * 1024 ))
    elif [[ "$threshold" =~ ^[0-9]+(KB|K)$ ]]; then
        echo $(( ${threshold%KB} * 1024 ))
    else
        echo "$threshold"  # Assume it's already in bytes
    fi
}

check_disk_space() {
    local disk="$1"
    local threshold="$2"

    # Convert threshold to bytes
    local min_free_space
    min_free_space=$(convertThreshold "$disk" "$threshold")

    # Get available space on the disk in bytes
    local available_space
    available_space=$(df --output=avail -B1 "$disk" | tail -1)

    # Check if available space is below the threshold
    if [[ "$available_space" -lt "$min_free_space" ]]; then
        logMessage "warn" "Free space on $disk ($(formatSpace $((available_space / 1024 / 1024)))) is below the threshold ($(formatSpace $((min_free_space / 1024 / 1024))))"
        return 1
    fi

    return 0
}

# Function to convert disk space reported in MB to GB for use in strings
formatSpace() {
    local diskSpace="$1"
    local formattedSpace

    # Ensure diskSpace is an integer
    if ! [[ "$diskSpace" =~ ^[0-9]+$ ]]; then
        logMessage "error" "Invalid disk space value: $diskSpace. Converting to integer."
        diskSpace=$(echo "$diskSpace" | awk '{print int($1)}')
    fi

    if [ "$diskSpace" -lt 1000 ]; then
        formattedSpace="${diskSpace} MB"
    elif [ "$diskSpace" -lt 1000000 ]; then
        formattedSpace=$(awk -v space="$diskSpace" 'BEGIN {printf "%.1f GB", space/1000}')
    else
        formattedSpace=$(awk -v space="$diskSpace" 'BEGIN {printf "%.1f TB", space/1000000}')
    fi

    # Remove trailing .0 if the number is a whole number
    formattedSpace=$(echo "$formattedSpace" | sed 's/\.0\([A-Z]\)/\1/')

    echo "$formattedSpace"
}

# Function to find the disk with the least free space greater than a specified value and enough space for dirSize (optional)
findLeastFreeDisk() {
    local dirSize="${1:-0}"  # Default to 0 if dirSize is not provided
    local leastFreeDisk=""
    local leastFreeSpace=-1

    for disk in "${!targetDisks[@]}"; do
        local freeSpace
        freeSpace=$(getFreeSpace "$disk")

        # Check if getFreeSpace returned a valid number
        if ! [[ "$freeSpace" =~ ^[0-9]+$ ]]; then
            logMessage "error" "Failed to get free space for disk: $disk"
            continue
        fi

        # Check if the disk has enough space for dirSize and is greater than minTargetDiskFreeSpace
        if [[ $freeSpace -gt $minTargetDiskFreeSpace && $freeSpace -ge $dirSize ]]; then
            if [[ -z $leastFreeDisk || $freeSpace -lt $leastFreeSpace ]]; then
                leastFreeDisk="$disk"
                leastFreeSpace="$freeSpace"
            fi
        fi
    done

    if [[ -z $leastFreeDisk ]]; then
        logMessage "warn" "No suitable disk found with free space greater than $minTargetDiskFreeSpace and enough space for directory size $dirSize"
    else
        logMessage "info" "Selected disk: $leastFreeDisk with free space: $leastFreeSpace"
    fi

    echo "$leastFreeDisk"
}

# Function to check available space on a disk
checkAvailableSpace() {
    local disk="$1"
    local requiredSpace="$2"
    local availableSpace=$(getFreeSpace $disk)

    # Compare available space with required space
    if (( availableSpace >= requiredSpace )); then
        return 0 # Sufficient space
    else
        return 1 # Insufficient space
    fi
}

transferDirectories() {
    local requiredSpace

    for dir in "${sourceDirectories[@]}"; do
        requiredSpace=$(du -sm "$dir" | awk '{print $1}')
        local transferred=false

        for disk in "${targetDisks[@]}"; do
            if checkAvailableSpace "$disk" "$requiredSpace"; then
                echo "Transferring $dir to $disk"
                rsync -a "$dir" "$disk/" &
                transferred=true
                break
            else
                logMessage "info" "Insufficient space on $disk for $dir"
            fi
        done

        if ! $transferred; then
            logMessage "error" "No target disks have sufficient space for $dir"
            return 1
        fi
    done

    # Wait for all background jobs to complete
    wait
}

# Function to calculate the total size of directories in the file list
calculateTotalSize() {
    awk '{total+=$1} END{print total}' "$fileListFilePath"
}

# Function to determine the destination disk for each directory based on available space
determineDestinations() {
    local disk="$1"

    for dir in "${sourceDirectories[@]}"; do
        # Skip if the directory does not exist on the source disk
        if ! checkDirectoryExists "${$diskPath/$disk/$dir}"; then
            continue
        fi

        # Find the destination disk with the least free space greater than the destination limit
        targetDisk=$(findLeastFreeDisk "$minTargetDiskFreeSpace")

        # Calculate the size of the directory
        dirSize=$(du -sm "$dir" 2>/dev/null | awk '{print $1}')

        # Append the directory, size, and destination disk to the file list
        echo "$dirSize $dir $targetDisk" >> "$fileListFilePath"
    done
}

# Function to add a header with date and time to the log file
addHeader() {
    echo -e "==== Movarr Results for $(date) ====\n" >>"$logFilePath"
}

# Function to add a footer with total data moved from and to each disk
addFooter() {
    # diskPaths=$activeDisks  # $sourceDisks

    local endTime=$(date +%s)
    local elapsedTime=$((endTime - startTime))

    local elapsedHours=$((elapsedTime / 3600))
    local elapsedMinutes=$(( (elapsedTime % 3600) / 60 ))
    local elapsedSeconds=$((elapsedTime % 60))

    echo "===== Summary =====" >> "$logFilePath"

    local totalDataMoved=""
    local totalDataAdded=""
    local totalDataRemoved=""

    for diskdisk in "${sourceDisks[@]}"; do
        # diskName=$(basename "$diskPath")

        movedData=$(du -sh "$disk" 2>/dev/null || echo "0M")
        totalDataMoved+="$disk: $movedData moved to "

        addedData=$(du -sh "$addedDataPath/$disk" 2>/dev/null || echo "0M")
        totalDataAdded+="$disk: $addedData, "

        removedData=$(du -sh "$removedDataPath/$disk" 2>/dev/null || echo "0M")
        totalDataRemoved+="$disk: $removedData, "
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

# Function to update the free space of a disk in the temporary file
updateFreeSpace() {
    local disk="$1"
    local sizeChange="$2"
    local tempFile="$3"

    # Read the current free space from the temporary file
    local currentFreeSpace
    currentFreeSpace=$(grep "^$disk " "$tempFile" | awk '{print $2}')

    # Calculate the new free space
    local newFreeSpace=$((currentFreeSpace + sizeChange))

    # Update the temporary file with the new free space
    sed -i "s/^$disk .*/$disk $newFreeSpace/" "$tempFile"
}

# Function to initialize the temporary file with the current free space of each disk
initializeTempFile() {
    local tempFile="$1"
    > "$tempFile"  # Clear the temporary file

    for disk in "${!sourceDisks[@]}"; do
        local freeSpace
        freeSpace=$(getFreeSpace "$disk")
        echo "$disk $freeSpace" >> "$tempFile"
    done

    for disk in "${!targetDisks[@]}"; do
        local freeSpace
        freeSpace=$(getFreeSpace "$disk")
        echo "$disk $freeSpace" >> "$tempFile"
    done
}

# calculateTotalSize() {
#     awk '{total+=$1} END{print total}' "$scriptDir/tmp_file.txt"  # "$fileListFilePath"
# }

# moveDirectory() {
#     local sourceDisk="$1"
#     local targetDisk="$2"
#     local directory="$3"
#     mv "$sourceDisk/$directory" "$targetDisk/"
# }

# createSimulationFile() {
#     local sourceDisk="$1"
#     local destinationDisk="$2"
#     echo "Simulating move from $sourceDisk to $destinationDisk" >> "$dryRunFilePath"
# }

isMovarrRunning() {
    [ -f "$scriptDir/movarr.pid" ]
}

checkDirectoryExists() {
    [ -d "$1" ]
}

# Function to format simulation entry
formatSimulationEntry() {
    local size="$1"
    local sourceDir="$2"
    local destDisk="$3"
    printf "%-10s %-40s %-20s\n" "$size" "$sourceDir" "$destDisk"
}

# Function to set destination disk in simulation file
setDestinationDisk() {
    echo -e "\n# $1" >> "$dryRunFilePath"
}

# Function to sort an associative array
sortAssociativeArray() {
    local -n arr=$1
    local -A sortedArr
    while IFS=$'\t' read -r key value; do
        sortedArr["$key"]=$value
    done < <(for key in "${!arr[@]}"; do echo -e "$key\t${arr[$key]}"; done | sort -k2 -n)
    echo "${!sortedArr[@]}"
}

# Function to generate a list of tentative files to move
generateMoveList() {
    local moveListFile="$1"
    > "$moveListFile"  # Clear the move list file

    for sourceDisk in "${!sourceDisks[@]}"; do
        for rootFolder in "${rootFolders[@]}"; do
            rootFolderPath="$diskPath/$sourceDisk/$rootFolder"
            if [ ! -d "$rootFolderPath" ]; then
                continue
            fi

            sourceDirectories=()
            while IFS= read -r dir; do
                sourceDirectories+=("$dir")
            done < <(find "$rootFolderPath" -maxdepth 1 -mindepth 1 -type d)

            for dir in "${sourceDirectories[@]}"; do
                dirSize=$(du -sm "$dir" 2>/dev/null | awk '{print $1}')
                if [ -z "$dirSize" ]; then
                    continue
                fi

                targetDisk=$(findLeastFreeDisk "$dirSize")
                if [ -z "$targetDisk" ]; then
                    continue
                fi

                echo "$dirSize $dir $targetDisk" >> "$moveListFile"
            done
        done
    done
}

# Function to move files based on the move list
moveFilesFromList() {
    local moveListFile="$1"
    while IFS= read -r line; do
        dirSize=$(echo "$line" | awk '{print $1}')
        dir=$(echo "$line" | awk '{print $2}')
        targetDisk=$(echo "$line" | awk '{print $3}')

        targetDir=$(echo "$dir" | sed "s:$diskPath/$sourceDisk:$diskPath/$targetDisk:")
        rsync -avz --remove-source-files --progress -- "$dir/" "$targetDir/" &
        
        while [ "$(jobs -r | wc -l)" -ge "$fileTransferLimit" ]; do
            sleep 1
        done
    done < "$moveListFile"

    wait
}

main() {
    # Initialize logs
    initializeLogs

    # Validate configuration and populate activeDisks
    validateConfiguration
    
    # Delete any existing simulation file if not in dryRun mode
    if [ "$dryRun" == "true" ]; then
        logMessage "debug,info" "Starting data transfer simulation"
        # Create a new simulation file
        > "$dryRunFilePath"
    else
        logMessage "debug,info" "Starting data transfer..."
        if [ -f "$dryRunFilePath" ]; then
            rm -f "$dryRunFilePath"
        fi
    fi

    # Identify source and target disks
    declare -A sourceDisks
    declare -A targetDisks

    logMessage "debug" "Found disks: $(printf "%s, " "${activeDisks[@]}" | sed 's/, $//')"

    logMessage "debug,info" "Processing disks:"
    logMessage "debug" "  Calculating free space..."

    for disk in "${activeDisks[@]}"; do
        if arrayContainsDisk "${excludedDisks[@]}" "$disk" ; then
            logMessage "info" "    $disk: Skipping excluded disk"
            continue
        fi

        # Get free space for the disk
        freeSpace=$(getFreeSpace "$disk")

        logMessage "debug" "    $disk: $(formatSpace $freeSpace)"
        if [ "$freeSpace" -lt "$minFreeDiskSpace" ]; then
            # Disk space is less than the minimum threshold
            sourceDisks["$disk"]=$freeSpace
            logMessage "info" "  Adding $disk to source disks due to low free space"
        else
            targetDisks["$disk"]=$freeSpace
            logMessage "info" "  Adding $disk to target disks"
        fi
    done

    logMessage "debug" "  Evaluating disks..."
    logMessage "debug" "    Source disks: ${!sourceDisks[@]}"
    logMessage "debug" "    Target disks: ${!targetDisks[@]}"
    logMessage "debug,info" "Sorting disks by available free space..."

    # Create a temporary file to track the simulated movement of data
    tempFile=$(mktemp)
    initializeTempFile "$tempFile"

    # List to track missing directories
    missingDirectories=()

    # Dictionary to track moved directories and their sizes
    declare -A movedDirectories
    declare -A movedData

    moveListFile=$(mktemp)
    generateMoveList "$moveListFile"

    if [ "$dryRun" == "true" ]; then
        logMessage "debug,info" "Simulation mode: Transfer plan saved to $dryRunFilePath."
        # Copy the move list to the dry run file for inspection
        cp "$moveListFile" "$dryRunFilePath"
        exit 0
    fi

    moveFilesFromList "$moveListFile"

    # Main loop
    while :; do
        moveNeeded=false

        # Iterate over each source disk
        for sourceDisk in "${!sourceDisks[@]}"; do
            logMessage "debug" "  $sourceDisk:"

            # Check if the source disk should be excluded from searching
            if arrayContainsDisk "${excludeSourceDisks[@]}" "$sourceDisk"; then
                logMessage "debug" "    Skipping excluded source disk"
                continue
            fi

            # Iterate over each root folder
            for rootFolder in "${rootFolders[@]}"; do
                rootFolderPath="$diskPath/$sourceDisk/$rootFolder"

                # Check if the root folder exists
                if [ ! -d "$rootFolderPath" ]; then
                    logMessage "debug,info" "    Root folder $rootFolderPath not found on $sourceDisk"
                    continue
                else
                    logMessage "debug" "    Root folder exists"
                fi

                # List all directories on the source disk
                sourceDirectories=()
                while IFS= read -r dir; do
                    sourceDirectories+=("$dir")
                done < <(find "$rootFolderPath" -maxdepth 1 -mindepth 1 -type d)
                
                # Skip if no directories found
                if [ ${#sourceDirectories[@]} -eq 0 ]; then
                    logMessage "info" "    No directories found on $sourceDisk for transfer."
                    continue
                fi

                # Function to get the sort key based on moverMode
                getSortKey() {
                    local dir="$1"
                    case "$moverMode" in
                        "largest" | "smallest")
                            du -s "$dir" | awk '{print $1}'
                            ;;
                        "oldest" | "newest")
                            stat -c %W "$dir" 2>/dev/null || stat -c %Y "$dir"
                            ;;
                        *)
                            echo "$dir"
                            ;;
                    esac
                }

                # Sort directories based on moverMode
                if [ "$moverMode" == "largest" ] || [ "$moverMode" == "smallest" ]; then
                    readarray -t sourceDirectories < <(for dir in "${sourceDirectories[@]}"; do
                        echo "$(getSortKey "$dir") $dir"
                    done | sort -k1,1n | awk '{print substr($0, index($0,$2))}')
                elif [ "$moverMode" == "oldest" ] || [ "$moverMode" == "newest" ]; then
                    readarray -t sourceDirectories < <(for dir in "${sourceDirectories[@]}"; do
                        echo "$(getSortKey "$dir") $dir"
                    done | sort -k1,1n | awk '{print substr($0, index($0,$2))}')
                fi

                # Reverse the order for largest and newest
                if [[ "$moverMode" == "largest" || "$moverMode" == "newest" ]]; then
                    readarray -t sourceDirectories < <(printf "%s\n" "${sourceDirectories[@]}" | tac)
                fi

                # List all directories on the source disk in the debug log
                if [ "$logLevel" == "trace" ]; then
                    logMessage "debug" "Directories found on $sourceDisk:"
                    for dir in "${sourceDirectories[@]}"; do
                        if [ "$moverMode" == "largest" ] || [ "$moverMode" == "smallest" ]; then
                            size=$(du -sh "$dir" | awk '{print $1}')
                            logMessage "debug" "  [$size] $dir"
                        elif [ "$moverMode" == "oldest" ] || [ "$moverMode" == "newest" ]; then
                            dateAdded=$(stat -c %y "$dir")
                            logMessage "debug" "  [$dateAdded] $dir"
                        else
                            logMessage "debug" "  $dir"
                        fi
                    done
                fi
            done

            # Retrieve free space for the source disk from the temporary file
            freeSpace=$(grep "^$sourceDisk " "$tempFile" | awk '{print $2}')

            logMessage "debug" "    Free space is $(formatSpace $freeSpace) < $(formatSpace $maxSourceDiskFreeSpace)"
            logMessage "debug" "    Searching $rootFolderPath/..."

            # Check if free space is less than or equal to zero
            while [ "$freeSpace" -le $maxSourceDiskFreeSpace ]; do
                moveNeeded=true

                # Iterate over each available directory
                for dir in "${sourceDirectories[@]}"; do
                    # Get the size of the directory
                    dirSize=$(du -sm "$dir" 2>/dev/null | awk '{print $1}')
                    if [ -z "$dirSize" ]; then
                        missingDirectories+=("$dir")
                        continue
                    fi

                    # Find the next destination disk with enough space for dirSize
                    targetDisk=$(findLeastFreeDisk "$dirSize")

                    # If no suitable destination disk is found, log an error and skip this directory
                    if [ -z "$targetDisk" ]; then
                        logMessage "error" "    No destination disk found with enough space for $dir (size: $(formatSpace $dirSize))."
                        continue
                    fi

                    # Add a new section to the simulation file if switching disks
                    if [ "$targetDisk" != "$currentDisk" ]; then
                        setDestinationDisk "$targetDisk"
                        currentDisk="$targetDisk"
                    fi

                    # Log the transfer to the simulation file
                    simulationEntry=$(formatSimulationEntry "$dirSize" "$dir" "$targetDisk")
                    echo "$simulationEntry" >> "$dryRunFilePath"

                    # Log the directory being moved
                    logMessage "debug,info" "      Moving $dir ($(formatSpace $dirSize)) to $targetDisk"

                    # Capture old free space for logging
                    oldSourceFreeSpace=$freeSpace
                    oldTargetFreeSpace=$(grep "^$targetDisk " "$tempFile" | awk '{print $2}')

                    # Update the free space in the temporary file
                    updateFreeSpace "$sourceDisk" "$dirSize" "$tempFile"
                    updateFreeSpace "$targetDisk" "$((-dirSize))" "$tempFile"

                    # Retrieve updated free space for the source and target disks
                    freeSpace=$(grep "^$sourceDisk " "$tempFile" | awk '{print $2}')
                    targetFreeSpace=$(grep "^$targetDisk " "$tempFile" | awk '{print $2}')
                    # logMessage "debug" "    Updated free space for source disk $sourceDisk from $(formatSpace $oldSourceFreeSpace) to $(formatSpace $freeSpace)"
                    # logMessage "debug" "    Updated free space for target disk $targetDisk from $(formatSpace $oldTargetFreeSpace) to $(formatSpace $targetFreeSpace)"

                    # Replace the source disk with the target disk in the $dir variable
                    targetDir=$(echo "$dir" | sed "s:$diskPath/$sourceDisk:$diskPath/$targetDisk:")

                    # Set the dry-run flag based on simulation mode
                    dryRunFlag=""
                    if [ "$dryRun" == "true" ]; then
                        dryRunFlag="--dry-run"
                    fi

                    # Perform the rsync operation
                    rsync -avz $dryRunFlag --remove-source-files --progress -- "$dir/" "$targetDir/"

                    # Check the exit status of rsync to confirm the transfer
                    if [ $? -eq 0 ]; then
                        # If rsync was successful, delete empty directories in the source
                        find "$dir" -depth -type d -empty -exec rmdir -- "{}" \; 2>/dev/null
                        echo "Transfer completed, and empty directories removed from source: $dir"
                    else
                        echo "rsync transfer failed. No files were deleted."
                        exit 1
                    fi

                    # Track moved directories and data
                    movedDirectories["$targetDisk"]+="$dir\n"
                    movedData["$targetDisk"]=$((movedData["$targetDisk"] + dirSize))

                    # Check if the minimum free disk space is reached
                    if [ "$freeSpace" -ge "$maxSourceDiskFreeSpace" ]; then
                        logMessage "debug" "    Free space on $sourceDisk is $(formatSpace $freeSpace). Moving to the next disk."
                        break
                    else
                        logMessage "debug" "     Free space has increased from $(formatSpace $oldSourceFreeSpace) to $(formatSpace $freeSpace). Continuing..."
                    fi

                done
            done
        done

        if ! $moveNeeded; then
            logMessage "debug" "All disks have been evaluated. No move needed."
            break
        else
            logMessage "debug" "All disks have been evaluated. Move recommended."
        fi

        # If in simulation mode, exit after creating the simulation file
        if [ "$dryRun" == "true" ]; then
            logMessage "debug,info" "Simulation mode: Transfer plan saved to $dryRunFilePath."
            # break
            exit 0
        fi

        # Start the transfer process
        logMessage "debug,info" "Starting data transfer..."

        transferDirectories "$sourceDisk" "$destinationDisk"

        # Limit the number of concurrent transfers
        logMessage "debug" "Limiting the number of concurrent transfers to $fileTransferLimit"
        while [ "$(jobs -r | wc -l)" -ge "$fileTransferLimit" ]; do
            sleep 1
        done
    done

    # Wait for all background jobs to complete
    logMessage "debug" "Waiting for all background jobs to complete..."
    wait

    # Log missing directories
    logMessage "debug" "Missing directories:"
    if [ ${#missingDirectories[@]} -gt 0 ]; then
        logMessage "debug,warn" "Missing Directories:"
        for missingDir in "${missingDirectories[@]}"; do
            logMessage "debug,warn" "  $missingDir"
        done
    fi

    # Clean up the temporary file
    rm -f "$tempFile"

    logMessage "info" "Movarr is done."
    logMessage "debug" "movarr.sh script completed."
}

# Ensure only one instance of movarr.sh is running
if isMovarrRunning; then
    logMessage "debug,info" "movarr.sh is already running. Exiting."
    exit 0
fi

# Log script start
logMessage "debug,info" "movarr.sh script started."

# Call the main function
main

# Format and log the simulation results
{
    for disk in "${!movedDirectories[@]}"; do
        echo "$disk:"
        echo -e "${movedDirectories[$disk]}" | while IFS= read -r dir; do
            echo "  [-] $dir"
        done
        totalFiles=$(echo -e "${movedDirectories[$disk]}" | wc -l)
        totalData=$(formatSpace "${movedData[$disk]}")
        echo "  Total files moved: $totalFiles"
        echo "  Total data transferred: $totalData"
    done
} > "$dryRunFilePath"

# Clean up the PID file
logMessage "debug" "Cleaning up PID file"
rm -f "$scriptDir/movarr.pid"