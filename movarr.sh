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
# backgroundTasks=false
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
fileListFileName="debug_file_list.txt"
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

initializeDryRun() {
    if [[ "$dryRun" == "true" ]] || [[ "$logLevel" == "debug" ]]; then
        # Initialize the dry run simulation file
        logMessage "debug" "Starting data transfer simulation"
        > "$dryRunFilePath"  # Clear the dry run simulation file
        echo "==== Movarr Simulation for $(date) ====" >> "$dryRunFilePath"
    else
        logMessage "debug,info" "Starting data transfer..."
        # Remove any existing simulation file
        if [ -f "$dryRunFilePath" ]; then
            rm -f "$dryRunFilePath"
        fi
    fi
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
    else
        echo "  dryRun: $dryRun" >> "$dryRunFilePath"
    fi

    # Validate logLevel (should be debug, info, warn, or error)
    logMessage "debug" "logLevel: $logLevel"
    if [ "$logLevel" != "trace" ] && [ "$logLevel" != "debug" ] && [ "$logLevel" != "info" ] && [ "$logLevel" != "warn" ] && [ "$logLevel" != "error" ]; then
        logMessage "error" "Invalid value for 'logLevel'. It should be one of: trace, debug, info, warn, error."
        ((errors++))
    else
        echo "  logLevel: $logLevel" >> "$dryRunFilePath"
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
    else
        echo "  maxLogSize: $maxLogSize" >> "$dryRunFilePath"
    fi

    # Validate maxLogRollovers (should be a positive integer)
    logMessage "debug" "maxLogRollovers: $maxLogRollovers"
    if ! [[ "$maxLogRollovers" =~ ^[1-9][0-9]*$ ]]; then
        logMessage "error" "Invalid value for 'maxLogRollovers'. It should be a positive integer."
        ((errors++))
    else
        echo "  maxLogRollovers: $maxLogRollovers" >> "$dryRunFilePath"
    fi

    # Validate diskPath (should be a valid directory)
    logMessage "debug" "diskPath: $diskPath"
    if [ ! -d "$diskPath" ]; then
        logMessage "error" "Invalid value for 'diskPath'. It should be a valid directory."
        ((errors++))
    else
        # Strip trailing slashes from diskPath
        diskPath=$(echo "$diskPath" | sed 's:/*$::')
        echo "  diskPath: $diskPath" >> "$dryRunFilePath"
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
            echo "  diskRegex: $diskRegex" >> "$dryRunFilePath"
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
        echo "  includeDisks: ${includeDisks[@]}" >> "$dryRunFilePath"
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
        echo "  excludeDisks: ${excludeDisks[@]}" >> "$dryRunFilePath"
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
        echo "  excludeSourceDisks: ${excludeSourceDisks[@]}" >> "$dryRunFilePath"
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
        echo "  excludeTargetDisks: ${excludeTargetDisks[@]}" >> "$dryRunFilePath"
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
        echo "  rootFolders: ${rootFolders[@]}" >> "$dryRunFilePath"
    fi

    # Validate minFreeDiskSpace, maxSourceDiskFreeSpace, and minTargetDiskFreeSpace
    minFreeDiskSpace=$(validateDiskSpace "$minFreeDiskSpace" "minFreeDiskSpace" "$errors")
    logMessage "debug" "minFreeDiskSpace: $(formatSpace $minFreeDiskSpace)"
    echo "  minFreeDiskSpace: $(formatSpace $minFreeDiskSpace)" >> "$dryRunFilePath"
    maxSourceDiskFreeSpace=$(validateDiskSpace "$maxSourceDiskFreeSpace" "maxSourceDiskFreeSpace" "$errors")
    logMessage "debug" "maxSourceDiskFreeSpace: $(formatSpace $maxSourceDiskFreeSpace)"
    echo "  maxSourceDiskFreeSpace: $(formatSpace $maxSourceDiskFreeSpace)" >> "$dryRunFilePath"
    minTargetDiskFreeSpace=$(validateDiskSpace "$minTargetDiskFreeSpace" "minTargetDiskFreeSpace" "$errors")
    logMessage "debug" "minTargetDiskFreeSpace: $(formatSpace $minTargetDiskFreeSpace)"
    echo "  minTargetDiskFreeSpace: $(formatSpace $minTargetDiskFreeSpace)" >> "$dryRunFilePath"

    # # Validate backgroundTasks (should be true or false)
    # logMessage "debug" "backgroundTasks: $backgroundTasks"
    # if [ "$backgroundTasks" != "true" ] && [ "$backgroundTasks" != "false" ]; then
    #     logMessage "error" "Invalid value for 'backgroundTasks'. It should be true or false."
    #     ((errors++))
    # else
    #     echo "  backgroundTasks: $backgroundTasks" >> "$dryRunFilePath"
    # fi

    # Validate fileTransferLimit (should be a positive integer and not exceed 10)
    logMessage "debug" "fileTransferLimit: $fileTransferLimit"
    if ! [[ "$fileTransferLimit" =~ ^[1-9][0-9]*$ ]] || [ "$fileTransferLimit" -gt 10 ]; then
        logMessage "error" "Invalid value for 'fileTransferLimit'. It should be a positive integer between 1 and 10."
        ((errors++))
    else
        echo "  fileTransferLimit: $fileTransferLimit" >> "$dryRunFilePath"
    fi

    # Validate moverMode (should be one of largest, smallest, oldest, newest)
    logMessage "debug" "moverMode: $moverMode"
    if [ "$moverMode" != "largest" ] && [ "$moverMode" != "smallest" ] && [ "$moverMode" != "oldest" ] && [ "$moverMode" != "newest" ]; then
        logMessage "error" "Invalid value for 'moverMode'. It should be one of: largest, smallest, oldest, newest."
        ((errors++))
    else
        echo "  moverMode: $moverMode" >> "$dryRunFilePath"
    fi

    # Validate notificationType (should be one of none, email, or pushbullet)
    logMessage "debug" "notificationType: $notificationType"
    if [ "$notificationType" != "none" ] && [ "$notificationType" != "unraid" ] && [ "$notificationType" != "email" ]; then
        logMessage "error" "Invalid value for 'notificationType'. It should be one of: none, unraid, email."
        ((errors++))
    else
        echo "  notificationType: $notificationType" >> "$dryRunFilePath"
    fi

    # Validate notifyEmail (should be a valid email address)
    logMessage "debug" "notifyEmail: $notifyEmail"
    if [ "$notificationType" = "email" ] && ! [[ "$notifyEmail" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        logMessage "error" "Invalid value for 'notifyEmail'. It should be a valid email address."
        ((errors++))
    else
        echo "  notifyEmail: $notifyEmail" >> "$dryRunFilePath"
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

# convertThreshold() {
#     local disk="$1"
#     local threshold="$2"

#     # Get total and available space on the disk in bytes
#     local total_space=$(df --output=size -B1 "$disk" | tail -1)
#     local available_space=$(df --output=avail -B1 "$disk" | tail -1)

#     # If threshold is in percentage format (e.g., "5%"), calculate equivalent bytes
#     if [[ "$threshold" =~ ^[0-9]+%$ ]]; then
#         local percent=${threshold%\%}  # Remove % sign
#         echo $((total_space * percent / 100))
#     elif [[ "$threshold" =~ ^[0-9]+(GB|G)$ ]]; then
#         echo $(( ${threshold%GB} * 1024 * 1024 * 1024 ))
#     elif [[ "$threshold" =~ ^[0-9]+(MB|M)$ ]]; then
#         echo $(( ${threshold%MB} * 1024 * 1024 ))
#     elif [[ "$threshold" =~ ^[0-9]+(KB|K)$ ]]; then
#         echo $(( ${threshold%KB} * 1024 ))
#     else
#         echo "$threshold"  # Assume it's already in bytes
#     fi
# }

# check_disk_space() {
#     local disk="$1"
#     local threshold="$2"

#     # Convert threshold to bytes
#     local min_free_space
#     min_free_space=$(convertThreshold "$disk" "$threshold")

#     # Get available space on the disk in bytes
#     local available_space
#     available_space=$(df --output=avail -B1 "$disk" | tail -1)

#     # Check if available space is below the threshold
#     if [[ "$available_space" -lt "$min_free_space" ]]; then
#         logMessage "warn" "Free space on $disk ($(formatSpace $((available_space / 1024 / 1024)))) is below the threshold ($(formatSpace $((min_free_space / 1024 / 1024))))"
#         return 1
#     fi

#     return 0
# }

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

# Function to find the disk with the least free space
findLeastFreeDisk() {
    local dirSize="$1"
    local tempFile="$2"

    # Initialize variables
    local targetDisk=""
    local leastFreeSpace=-1

    # logMessage "debug" "findLeastFreeDisk called with dirSize: $dirSize, tempFile: $tempFile"
    # logMessage "debug" "Target disks: ${!targetDisks[@]}"

    # Read the target disks list
    for disk in "${!targetDisks[@]}"; do
        # Get the free space for the current disk from the temp file
        local freeSpace=$(grep "^$disk " "$tempFile" | awk '{print $2}')

        # Ensure freeSpace is a valid number
        if [[ -z "$freeSpace" || ! "$freeSpace" =~ ^[0-9]+$ ]]; then
            # logMessage "debug" "Skipping disk $disk: No valid free space found"
            continue
        fi

        # logMessage "debug" "Checking disk: $disk with free space: $freeSpace"

        # Ensure the free space is enough for the directory and exceeds minTargetDiskFreeSpace
        if [[ "$freeSpace" -ge "$dirSize" && "$freeSpace" -gt "$minTargetDiskFreeSpace" ]]; then
            # logMessage "debug" "    Disk $disk has enough space. Free space: $freeSpace, dirSize: $dirSize, minTargetDiskFreeSpace: $minTargetDiskFreeSpace"

            # If it's the first valid disk or has less free space than the current least
            if [[ -z "$targetDisk" || "$freeSpace" -lt "$leastFreeSpace" ]]; then
                # logMessage "debug" "    Disk $disk selected as target (current least: $leastFreeSpace, new least: $freeSpace)"
                targetDisk="$disk"
                leastFreeSpace="$freeSpace"
            fi
        # else
            # logMessage "debug" "    Disk $disk skipped. Not enough space for dirSize or minTargetDiskFreeSpace."
        fi
    done

    echo "$targetDisk"
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

    for disk in "${sourceDisks[@]}"; do
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

isMovarrRunning() {
    [ -f "$scriptDir/movarr.pid" ]
}

# checkDirectoryExists() {
#     [ -d "$1" ]
# }

# Function to format simulation entry
formatSimulationEntry() {
    local size="$1"
    local sourceDir="$2"
    local destDisk="$3"
    printf "%-10s %-80s %-20s\n" "$size" "$sourceDir" "$destDisk"
}

# Function to set destination disk in simulation file
# setDestinationDisk() {
#     echo -e "\n# $1" >> "$dryRunFilePath"
# }

# Function to sort an associative array
# sortAssociativeArray() {
#     local -n arr=$1
#     local -A sortedArr
#     while IFS=$'\t' read -r key value; do
#         sortedArr["$key"]=$value
#     done < <(for key in "${!arr[@]}"; do echo -e "$key\t${arr[$key]}"; done | sort -k2 -n)
#     echo "${!sortedArr[@]}"
# }

generateMoveList() {
    local moveListFile="$1"
    > "$moveListFile"  # Clear the move list file

    if [ "$dryRun" == "true" ]; then
        > "$dryRunFilePath"  # Clear the dry run simulation file

        declare -A totalDataMovedTargetDisks
        declare -A totalDataMovedSourceDisks
    fi

    # Sort the sourceDisks array by disk size (ascending order)
    sortedSizeSourceDisks=$(for disk in "${!sourceDisks[@]}"; do echo "$disk ${sourceDisks[$disk]}"; done | sort -n -k2)

    # Iterate over sorted source disks (by ascending disk size)
    while read -r sourceDisk size; do
        logMessage "debug,info" "  $sourceDisk:"

        # Skip excluded disks
        if arrayContainsDisk "${excludeSourceDisks[@]}" "$sourceDisk"; then
            logMessage "debug" "    Skipping excluded source disk"
            continue
        fi

        # Dry run - log initial free space for the disk
        if [ "$dryRun" == "true" ]; then
            initialFreeSpace=$(grep "^$sourceDisk " "$tempFile" | awk '{print $2}')
            echo "  $sourceDisk (Available free space: $(formatSpace $initialFreeSpace), Target: $(formatSpace $minFreeDiskSpace))" >> "$dryRunFilePath"
            echo "    Moves:" >> "$dryRunFilePath"
        fi

        # Iterate over each root folder
        for rootFolder in "${rootFolders[@]}"; do
            rootFolderPath="$diskPath/$sourceDisk/$rootFolder"

            # Check if the root folder exists
            if [ ! -d "$rootFolderPath" ]; then
                logMessage "debug,info" "    Root folder $rootFolderPath not found on $sourceDisk"
                continue
            fi

            # List directories in rootFolderPath
            sourceDirectories=()
            while IFS= read -r dir; do
                sourceDirectories+=("$dir")
            done < <(find "$rootFolderPath" -maxdepth 1 -mindepth 1 -type d)

            # Skip if no directories found
            if [ ${#sourceDirectories[@]} -eq 0 ]; then
                logMessage "info" "    No directories found on $sourceDisk for transfer."
                continue
            fi

            # Function to get sorting key
            getSortKey() {
                local dir="$1"
                case "$moverMode" in
                    "largest" | "smallest") du -s "$dir" | awk '{print $1}' ;;
                    "oldest" | "newest") stat -c %W "$dir" 2>/dev/null || stat -c %Y "$dir" ;;
                    *) echo "$dir" ;;
                esac
            }

            # Sort directories based on moverMode
            if [[ "$moverMode" == "largest" || "$moverMode" == "smallest" || "$moverMode" == "oldest" || "$moverMode" == "newest" ]]; then
                readarray -t sourceDirectories < <(for dir in "${sourceDirectories[@]}"; do
                    # Skip inaccessible directories
                    if [[ " ${missingDirectories[@]} " =~ " $dir " ]]; then
                        continue
                    fi
                    
                    echo "$(getSortKey "$dir") $dir"
                done | sort -k1,1n | awk '{print substr($0, index($0,$2))}')
            fi

            # Reverse order for "largest" and "newest"
            if [[ "$moverMode" == "largest" || "$moverMode" == "newest" ]]; then
                readarray -t sourceDirectories < <(printf "%s\n" "${sourceDirectories[@]}" | tac)
            fi

            # Retrieve free space on the source disk
            freeSpace=$(grep "^$sourceDisk " "$tempFile" | awk '{print $2}')
            logMessage "debug" "    Free space on source disk ($sourceDisk) is $(formatSpace $freeSpace)"

            # Dry run - Initialize tracking for data moved
            if [ "$dryRun" == "true" ]; then
                unset dataMovedTargetDisks
                declare -A dataMovedTargetDisks
            fi

            # Iterate over each directory
            for sourceDir in "${sourceDirectories[@]}"; do
                sourceDirSize=$(du -sm "$sourceDir" 2>/dev/null | awk '{print $1}')
                if [ -z "$sourceDirSize" ]; then
                    # Directory cannot be accessed, add to missingDirectories array
                    missingDirectories+=("$sourceDir")
                    logMessage "warn" "    Directory $sourceDir cannot be accessed and will be added to missing directories."
                    continue
                fi

                # Find the best destination disk based on theoretical space from the temp file
                targetDisk=$(findLeastFreeDisk "$sourceDirSize" "$tempFile")
                if [ -z "$targetDisk" ]; then
                    logMessage "error" "    No destination disk found for $sourceDir (size: $(formatSpace $sourceDirSize))"
                    continue
                fi

                # Retrieve free space on the target disk
                targetDiskFreeSpace=$(grep "^$targetDisk " "$tempFile" | awk '{print $2}')
                logMessage "debug" "    Free space on target disk ($targetDisk) is $(formatSpace $targetDiskFreeSpace)"

                targetDir=$(echo "$sourceDir" | sed "s|^$diskPath/disk[0-9]\+|$diskPath/$targetDisk|")

                # Add move entry to move list file
                if [ "$dryRun" == "true" ]; then
                    echo "      \"$sourceDir\" ($(formatSpace $sourceDirSize))" >> "$dryRunFilePath"
                    echo "       ➥ \"$targetDir\"" >> "$dryRunFilePath"
                else
                    echo "$sourceDirSize \"$sourceDir\" \"$targetDir\"" >> "$moveListFile"
                fi

                logMessage "debug,info" "    Queued move: $sourceDir ($(formatSpace $sourceDirSize)) → $targetDisk"

                # Simulate updating free space
                updateFreeSpace "$sourceDisk" "$sourceDirSize" "$tempFile"
                updateFreeSpace "$targetDisk" "$((-sourceDirSize))" "$tempFile"

                # Retrieve updated free space on source disk
                sourceDiskfreeSpace=$(grep "^$sourceDisk " "$tempFile" | awk '{print $2}')
                logMessage "debug" "    Updated free space on source disk ($sourceDisk) is $(formatSpace $sourceDiskfreeSpace)"

                # Retrieve updated free space on target disk
                targetDiskFreeSpace=$(grep "^$targetDisk " "$tempFile" | awk '{print $2}')
                logMessage "debug" "    Updated free space on target disk ($targetDisk) is $(formatSpace $targetDiskFreeSpace)"

                # Track total data moved from the source disk
                if [ "$dryRun" == "true" ]; then
                    totalDataMovedSourceDisks[$sourceDisk]=$((totalDataMovedSourceDisks[$sourceDisk] + sourceDirSize))
                    totalDataMovedTargetDisks[$targetDisk]=$((totalDataMovedTargetDisks[$targetDisk] + sourceDirSize))
                    dataMovedTargetDisks[$targetDisk]=$((dataMovedTargetDisks[$targetDisk] + sourceDirSize))
                fi

                # Check if enough free space has been reached on the source disk
                if [ "$sourceDiskfreeSpace" -ge "$maxSourceDiskFreeSpace" ]; then
                    logMessage "debug" "    Free space on source disk ($sourceDisk) exceeds minimum threshold."
                    break
                else
                    # Check if the disk has enough space for the next directory
                    nextSourceDir=$(echo "${sourceDirectories[1]}" | awk '{print $2}')
                    nextSourceDirSize=$(du -sm "$nextSourceDir" 2>/dev/null | awk '{print $1}')
                    if [ -z "$nextSourceDirSize" ]; then
                        continue
                    fi

                    if [ "$((targetDiskFreeSpace - nextSourceDirSize))" -lt "$maxSourceDiskFreeSpace" ]; then
                        logMessage "debug" "    Not enough space on target disk ($targetDisk) for the next directory."
                        break
                    fi
                fi
            done
            
            # Dry run - Log the total data moved for the disk
            if [ "$dryRun" == "true" ]; then
                echo "    Summary:" >> "$dryRunFilePath"
                echo "      [-] $sourceDisk: $(formatSpace ${totalDataMovedSourceDisks[$sourceDisk]})" >> "$dryRunFilePath"

                for targetDisk in "${!dataMovedTargetDisks[@]}"; do
                    echo "      [+] $targetDisk: $(formatSpace ${dataMovedTargetDisks[$targetDisk]})" >> "$dryRunFilePath"
                done

                echo "" >> "$dryRunFilePath"
            fi
        done
    done <<< "$sortedSizeSourceDisks"

    # Dry run - Add footer to the simulation file
    if [ "$dryRun" == "true" ]; then
        # Log the total data moved for each disk
        echo "Total Data Moved:" >> "$dryRunFilePath"
        for disk in "${!totalDataMovedSourceDisks[@]}"; do
            echo "  $disk: $(formatSpace ${totalDataMovedSourceDisks[$disk]})" >> "$dryRunFilePath"
        done
        echo "" >> "$dryRunFilePath"
        echo "Total Data Added:" >> "$dryRunFilePath"
        for disk in "${!totalDataMovedTargetDisks[@]}"; do
            echo "  $disk: $(formatSpace ${totalDataMovedTargetDisks[$disk]})" >> "$dryRunFilePath"
        done
        echo "" >> "$dryRunFilePath"

        addFooter >> "$dryRunFilePath"
    fi

    # Iterate over missing directories
    if [ ${#missingDirectories[@]} -gt 0 ]; then
        logMessage "debug,warn" "Missing directories:"
        for dir in "${missingDirectories[@]}"; do
            logMessage "debug,warn" "  $dir"
        done
    else
        logMessage "debug" "No missing directories found."
    fi
}

moveFilesFromList() {
    local moveListFile="$1"
    local sourceDirSize
    local sourceDir
    local targetDir
    local targetDisk

    while IFS= read -r line; do
        # Match the pattern with numbers followed by quoted paths
        if [[ $line =~ ^([0-9]+)\ [\"']([^\"]+)[\"']\ [\"']([^\"]+)[\"']$ ]]; then
            sourceDirSize="${BASH_REMATCH[1]}"
            sourceDir="${BASH_REMATCH[2]}"
            targetDir="${BASH_REMATCH[3]}"
            targetDisk=$(echo "$targetDir" | awk -F'/' '{print $3}')
        else
            logMessage "error" "Failed to parse line: $line"
            continue  # Skip to next line if parsing fails
        fi

        # Ensure source directory exists
        if [ ! -d "$sourceDir" ]; then
            logMessage "error" "Source directory $sourceDir does not exist. Skipping move."
            continue
        fi

        # Execute rsync (without dry-run for actual move)
        rsync -avz --remove-source-files --progress -- "$sourceDir/" "$targetDir/" &

        # Remove empty directories after transfer
        find "$sourceDir" -type d -empty -exec rmdir {} \;

        # Track moved directories and their sizes
        # movedDirectories["$targetDisk"]+="$sourceDir\n"
        # movedData["$targetDisk"]=$((movedData["$targetDisk"] + sourceDirSize))

        # Limit the number of concurrent transfers
        while [ "$(jobs -r | wc -l)" -ge "$fileTransferLimit" ]; do
            sleep 1
        done
    done < "$moveListFile"

    # Wait for all background jobs to finish
    wait
}

main() {
    # Initialize logs
    initializeLogs
    initializeDryRun

    if [ "$dryRun" == "true" ]; then
        echo "Configuration Settings:" >> "$dryRunFilePath"
    fi

    # Validate configuration and populate activeDisks
    validateConfiguration
    
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
            # Disk space is sufficient
            targetDisks["$disk"]=$freeSpace
            logMessage "info" "  Adding $disk to target disks"
        fi
    done
    
    logMessage "debug" "  Analyzing disks..."

    # Sort source disks by name
    sortedNameSourceDisks=($(for disk in "${!sourceDisks[@]}"; do echo "$disk"; done | sort -V))
    sortedNameTargetDisks=($(for disk in "${!targetDisks[@]}"; do echo "$disk"; done | sort -V))

    logMessage "debug" "    Source disks: ${sortedNameSourceDisks[@]}"
    logMessage "debug" "    Target disks: ${sortedNameTargetDisks[@]}"

    echo "Disks:" >> "$dryRunFilePath"
    echo "  Source: ${sortedNameSourceDisks[@]}" >> "$dryRunFilePath"
    echo "  Target: ${sortedNameTargetDisks[@]}" >> "$dryRunFilePath"
    echo "" >> "$dryRunFilePath"

    # Create a temporary file to track the simulated movement of data
    tempFile=$(mktemp "$scriptDir/tmp.XXXXXX")

    # Delete any existing tempFiles from a previous dry run in scriptDir
    find "$scriptDir" -name 'tmp.*' -type f -exec rm -f {} \;

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

        # Exit without moving files
        exit 0
    elif [ "$logLevel" == "debug" ]; then
        logMessage "debug,info" "Debug mode: Transfer plan saved to $dryRunFilePath."
        cp "$moveListFile" "$fileListFilePath"
    fi

    moveFilesFromList "$moveListFile"

    # Wait for all background jobs to complete
    logMessage "debug" "Waiting for all background jobs to complete..."
    # timeout 600 wait || logMessage "warn" "Background jobs took too long to complete."
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
    if [ "$dryRun" != "true" ] && [ "$logLevel" != "debug" ]; then
        rm -f "$tempFile"
    fi

    logMessage "info" "Movarr is done."
    logMessage "debug" "movarr.sh script completed."

    # Add footer with summary
    addFooter
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
# {
#     for disk in "${!movedDirectories[@]}"; do
#         echo "$disk:"
#         echo -e "${movedDirectories[$disk]}" | while IFS= read -r dir; do
#             echo "  [-] $dir"
#         done
#         totalFiles=$(echo -e "${movedDirectories[$disk]}" | wc -l)
#         totalData=$(formatSpace "${movedData[$disk]}")
#         echo "  Total files moved: $totalFiles"
#         echo "  Total data transferred: $totalData"
#     done
# } > "$dryRunFilePath"

# Clean up the PID file
logMessage "debug" "Cleaning up PID file"
rm -f "$scriptDir/movarr.pid"