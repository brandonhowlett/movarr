#!/bin/bash

# movarr.sh - Script to transfer directories from source disks to target disks
# based on available space, with optional simulation mode.

startTime=$(date +%s)

# Configuration variables
dryRun=false
logLevel="info"
maxLogSize=1
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
fileTransferLimit=1
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

# Function to log messages
logMessage() {
    local logLevels="$1"
    shift
    local logMessage="$@"
    local lineNumber="${BASH_LINENO[0]}"

    if [ -z "$logFilePath" ]; then
        echo "$(date +"%Y-%m-%d %H:%M:%S") [ERROR] [$lineNumber] logFilePath is not set."
        return 1
    fi

    if [ -f "$logFilePath" ]; then
        logFileSize=$(du -m "$logFilePath" | cut -f1)
        if [ "$logFileSize" -ge "$maxLogSize" ]; then
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
                echo "$(date +"%Y-%m-%d %H:%M:%S") [$logLevel] [$lineNumber] $logMessage"
                ;;
            "info" | "warn" | "error")
                echo "$(date +"%Y-%m-%d %H:%M:%S") [$logLevel] $logMessage" >>"$logFilePath"
                if [ "$notificationType" != "none" ]; then
                    case "$notificationType" in
                        "email")
                            echo "$logMessage" | mail -s "Movarr Notification - $logLevel" "$notifyEmail"
                            ;;
                        "unraid")
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

# Function to initialize logs and handle log rollover
initializeLogs() {
    mkdir -p "$scriptDir/logs"
    logFiles=("$scriptDir/logs/movarr"*.log)
    logCount=${#logFiles[@]}
    if [ "$logCount" -gt "$maxLogRollovers" ]; then
        filesToRemove=$((logCount - maxLogRollovers))
        for ((i = 0; i < filesToRemove; i++)); do
            rm -f "${logFiles[$i]}"
        done
    fi
    if [ ! -f "$logFilePath" ]; then
        touch "$logFilePath"
        chmod 644 "$logFilePath"
    fi
    addHeader "$logFilePath"
}

initializeDryRun() {
    if [[ "$dryRun" == "true" ]] || [[ "$logLevel" == "debug" ]]; then
        logMessage "debug" "Starting data transfer simulation"
        > "$dryRunFilePath"
        echo "==== Movarr Simulation for $(date) ====" >> "$dryRunFilePath"
    else
        logMessage "debug,info" "Starting data transfer..."
        [ -f "$dryRunFilePath" ] && rm -f "$dryRunFilePath"
    fi
}

# Function to validate disk space
validateDiskSpace() {
    local spaceValue="$1"
    local spaceName="$2"
    local errors="$3"

    if [[ "$spaceValue" =~ ^([0-9]+)[[:space:]]*(MB|GB)?$ ]]; then
        size=${BASH_REMATCH[1]}
        unit=${BASH_REMATCH[2]}
        [ -z "$unit" ] && unit="GB"
        [ "$unit" == "GB" ] && spaceValue=$((size * 1024)) || spaceValue=$size
    else
        ((errors++))
    fi

    echo "$spaceValue"
}

# Function to validate configuration imported from config.ini
validateConfiguration() {
    local errors=0

    logMessage "debug" "Validating configuration..."
    [ "$dryRun" == "true" ] && echo "Configuration Settings:" >> "$dryRunFilePath"

    logMessage "debug" "dryRun: $dryRun"
    [ "$dryRun" == "true" ] && echo "  dryRun: $dryRun" >> "$dryRunFilePath"
    if [ "$dryRun" != "true" ] && [ "$dryRun" != "false" ]; then
        logMessage "error" "Invalid value for 'dryRun'. It should be true or false."
        ((errors++))
    fi

    logMessage "debug" "logLevel: $logLevel"
    [ "$dryRun" == "true" ] && echo "  logLevel: $logLevel" >> "$dryRunFilePath"
    if [ "$logLevel" != "trace" ] && [ "$logLevel" != "debug" ] && [ "$logLevel" != "info" ] && [ "$logLevel" != "warn" ] && [ "$logLevel" != "error" ]; then
        logMessage "error" "Invalid value for 'logLevel'. It should be one of: trace, debug, info, warn, error."
        ((errors++))
    fi

    logMessage "debug" "maxLogSize: $maxLogSize"
    [ "$dryRun" == "true" ] && echo "  maxLogSize: $maxLogSize" >> "$dryRunFilePath"
    if ! [[ "$maxLogSize" =~ ^[1-9][0-9]*$ ]]; then
        logMessage "error" "Invalid value for 'maxLogSize'. It should be a positive integer."
        ((errors++))
    fi

    logMessage "debug" "maxLogRollovers: $maxLogRollovers"
    [ "$dryRun" == "true" ] && echo "  maxLogRollovers: $maxLogRollovers" >> "$dryRunFilePath"
    if ! [[ "$maxLogRollovers" =~ ^[1-9][0-9]*$ ]]; then
        logMessage "error" "Invalid value for 'maxLogRollovers'. It should be a positive integer."
        ((errors++))
    fi

    logMessage "debug" "diskPath: $diskPath"
    [ "$dryRun" == "true" ] && echo "  diskPath: $diskPath" >> "$dryRunFilePath"
    if [ ! -d "$diskPath" ]; then
        logMessage "error" "Invalid value for 'diskPath'. It should be a valid directory."
        ((errors++))
    else
        diskPath=$(echo "$diskPath" | sed 's:/*$::')
    fi

    logMessage "debug" "diskRegex: $diskRegex"
    [ "$dryRun" == "true" ] && echo "  diskRegex: $diskRegex" >> "$dryRunFilePath"
    if [ -n "$diskRegex" ]; then
        matchingDisks=()
        for disk in $(ls "$diskPath"); do
            [[ "$disk" =~ $diskRegex ]] && matchingDisks+=("$disk")
        done

        if [ ${#matchingDisks[@]} -eq 0 ]; then
            logMessage "error" "No disks in '$diskPath' match the regex pattern '$diskRegex'."
            ((errors++))
        else
            activeDisks=("${matchingDisks[@]}")
        fi
    fi

    logMessage "debug" "includeDisks: ${includeDisks[@]}"
    [ "$dryRun" == "true" ] && echo "  includeDisks: ${includeDisks[@]}" >> "$dryRunFilePath"
    if [ ${#includeDisks[@]} -ne 0 ]; then
        for disk in "${includeDisks[@]}"; do
            logMessage "debug" "Validating includeDisk: $disk"
            if [ -d "$diskPath/$disk" ]; then
                logMessage "debug" "Disk '$disk' exists in '$diskPath'"
                [[ ! " ${activeDisks[@]} " =~ " $disk " ]] && activeDisks+=("$disk")
            else
                logMessage "error" "Disk '$disk' in 'includeDisks' does not exist in '$diskPath'."
                ((errors++))
            fi
        done
    fi

    logMessage "debug" "excludeDisks: ${excludeDisks[@]}"
    [ "$dryRun" == "true" ] && echo "  excludeDisks: ${excludeDisks[@]}" >> "$dryRunFilePath"
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

    logMessage "debug" "excludeSourceDisks: ${excludeSourceDisks[@]}"
    [ "$dryRun" == "true" ] && echo "  excludeSourceDisks: ${excludeSourceDisks[@]}" >> "$dryRunFilePath"
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

    logMessage "debug" "excludeTargetDisks: ${excludeTargetDisks[@]}"
    [ "$dryRun" == "true" ] && echo "  excludeTargetDisks: ${excludeTargetDisks[@]}" >> "$dryRunFilePath"
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

    logMessage "debug" "rootFolders: ${rootFolders[@]}"
    [ "$dryRun" == "true" ] && echo "  rootFolders: ${rootFolders[@]}" >> "$dryRunFilePath"
    if [ ${#rootFolders[@]} -ne 0 ]; then
        for i in "${!rootFolders[@]}"; do
            rootFolderPath="${rootFolders[$i]}"
            logMessage "debug" "Validating rootFolder: $rootFolderPath"
            rootFolderPathExists=false
            for disk in "${activeDisks[@]}"; do
                [[ " ${excludedSourceDisks[@]} " =~ " $disk " ]] && continue
                disk=$(echo "$disk" | sed 's:/*$::')
                strippedRootFolderPath=$(echo "$rootFolderPath" | sed 's:^/*::')
                if [ -d "$diskPath/$disk/$strippedRootFolderPath" ]; then
                    rootFolderPathExists=true
                    break
                fi
            done
            if [ "$rootFolderPathExists" = false ]; then
                logMessage "error" "Directory '$rootFolderPath' in 'rootFolders' does not exist in any of the source disks."
                ((errors++))
            else
                rootFolders[$i]="$strippedRootFolderPath"
            fi
        done
    fi

    logMessage "debug" "minFreeDiskSpace: $(formatSpace $minFreeDiskSpace)"
    echo "  minFreeDiskSpace: $(formatSpace $minFreeDiskSpace)" >> "$dryRunFilePath"
    minFreeDiskSpace=$(validateDiskSpace "$minFreeDiskSpace" "minFreeDiskSpace" "$errors")

    logMessage "debug" "maxSourceDiskFreeSpace: $(formatSpace $maxSourceDiskFreeSpace)"
    echo "  maxSourceDiskFreeSpace: $(formatSpace $maxSourceDiskFreeSpace)" >> "$dryRunFilePath"
    maxSourceDiskFreeSpace=$(validateDiskSpace "$maxSourceDiskFreeSpace" "maxSourceDiskFreeSpace" "$errors")

    logMessage "debug" "minTargetDiskFreeSpace: $(formatSpace $minTargetDiskFreeSpace)"
    echo "  minTargetDiskFreeSpace: $(formatSpace $minTargetDiskFreeSpace)" >> "$dryRunFilePath"
    minTargetDiskFreeSpace=$(validateDiskSpace "$minTargetDiskFreeSpace" "minTargetDiskFreeSpace" "$errors")

    logMessage "debug" "fileTransferLimit: $fileTransferLimit"
    [ "$dryRun" == "true" ] && echo "  fileTransferLimit: $fileTransferLimit" >> "$dryRunFilePath"
    if ! [[ "$fileTransferLimit" =~ ^[1-9][0-9]*$ ]] || [ "$fileTransferLimit" -gt 10 ]; then
        logMessage "error" "Invalid value for 'fileTransferLimit'. It should be a positive integer between 1 and 10."
        ((errors++))
    fi

    logMessage "debug" "moverMode: $moverMode"
    [ "$dryRun" == "true" ] && echo "  moverMode: $moverMode" >> "$dryRunFilePath"
    if [ "$moverMode" != "largest" ] && [ "$moverMode" != "smallest" ] && [ "$moverMode" != "oldest" ] && [ "$moverMode" != "newest" ]; then
        logMessage "error" "Invalid value for 'moverMode'. It should be one of: largest, smallest, oldest, newest."
        ((errors++))
    fi

    logMessage "debug" "notificationType: $notificationType"
    [ "$dryRun" == "true" ] && echo "  notificationType: $notificationType" >> "$dryRunFilePath"
    if [ "$notificationType" != "none" ] && [ "$notificationType" != "unraid" ] && [ "$notificationType" != "email" ]; then
        logMessage "error" "Invalid value for 'notificationType'. It should be one of: none, unraid, email."
        ((errors++))
    fi

    logMessage "debug" "notifyEmail: $notifyEmail"
    [ "$dryRun" == "true" ] && echo "  notifyEmail: $notifyEmail" >> "$dryRunFilePath"
    if [ "$notificationType" = "email" ] && ! [[ "$notifyEmail" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        logMessage "error" "Invalid value for 'notifyEmail'. It should be a valid email address."
        ((errors++))
    fi

    if [ "$errors" -gt 0 ]; then
        logMessage "error" "Configuration validation failed with $errors errors."
        exit 1
    fi

    activeDisks=($(printf "%s\n" "${activeDisks[@]}" | sort -V))

    logMessage "info" "Configuration validation completed successfully."
}

arrayContainsDisk() {
    local array=("$@")
    local seeking=${array[-1]}
    unset array[-1]
    for element in "${array[@]}"; do
        [[ "$element" == "$seeking" ]] && return 0
    done
    return 1
}

getFreeSpace() {
    df -m "$diskPath/$1" | awk 'NR==2 {print $4}'
}

formatSpace() {
    local diskSpace="$1"
    local formattedSpace

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

    formattedSpace=$(echo "$formattedSpace" | sed 's/\.0\([A-Z]\)/\1/')

    echo "$formattedSpace"
}

findLeastFreeDisk() {
    local dirSize="$1"
    local tempFile="$2"

    local targetDisk=""
    local leastFreeSpace=-1

    for disk in "${!targetDisks[@]}"; do
        local freeSpace=$(grep "^$disk " "$tempFile" | awk '{print $2}')

        if [[ -z "$freeSpace" || ! "$freeSpace" =~ ^[0-9]+$ ]]; then
            continue
        fi

        if [[ "$freeSpace" -ge "$dirSize" && "$freeSpace" -gt "$minTargetDiskFreeSpace" ]]; then
            if [[ -z "$targetDisk" || "$freeSpace" -lt "$leastFreeSpace" ]]; then
                targetDisk="$disk"
                leastFreeSpace="$freeSpace"
            fi
        fi
    done

    echo "$targetDisk"
}

addHeader() {
    echo -e "==== Movarr Results for $(date) ====\n" >>"$logFilePath"
}

addFooter() {
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
        movedData=$(du -sh "$disk" 2>/dev/null || echo "0M")
        totalDataMoved+="$disk: $movedData moved to "

        addedData=$(du -sh "$addedDataPath/$disk" 2>/dev/null || echo "0M")
        totalDataAdded+="$disk: $addedData, "

        removedData=$(du -sh "$removedDataPath/$disk" 2>/dev/null || echo "0M")
        totalDataRemoved+="$disk: $removedData, "
    done

    totalDataAdded="${totalDataAdded%,*}"
    totalDataRemoved="${totalDataRemoved%,*}"

    logMessage "info" "$totalDataMoved"
    logMessage "info" "$totalDataAdded moved from"
    logMessage "info" "$totalDataRemoved"
    logMessage "info" "---------------------------"
    logMessage "info" "Total Data Moved: $totalDataMoved"
    logMessage "info" "Script Execution Time: ${elapsedHours}h ${elapsedMinutes}m ${elapsedSeconds}s"
}

updateFreeSpace() {
    local disk="$1"
    local sizeChange="$2"
    local tempFile="$3"

    local currentFreeSpace
    currentFreeSpace=$(grep "^$disk " "$tempFile" | awk '{print $2}')

    local newFreeSpace=$((currentFreeSpace + sizeChange))

    sed -i "s/^$disk .*/$disk $newFreeSpace/" "$tempFile"
}

initializeTempFile() {
    local tempFile="$1"
    > "$tempFile"

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

formatSimulationEntry() {
    local size="$1"
    local sourceDir="$2"
    local destDisk="$3"
    printf "%-10s %-80s %-20s\n" "$size" "$sourceDir" "$destDisk"
}

generateMoveList() {
    local moveListFile="$1"
    > "$moveListFile"

    if [ "$dryRun" == "true" ]; then
        > "$dryRunFilePath"

        declare -A totalDataMovedTargetDisks
        declare -A totalDataMovedSourceDisks
    fi

    sortedSizeSourceDisks=$(for disk in "${!sourceDisks[@]}"; do echo "$disk ${sourceDisks[$disk]}"; done | sort -n -k2)

    while read -r sourceDisk size; do
        logMessage "debug,info" "  $sourceDisk:"

        if arrayContainsDisk "${excludeSourceDisks[@]}" "$sourceDisk"; then
            logMessage "debug" "    Skipping excluded source disk"
            continue
        fi

        if [ "$dryRun" == "true" ]; then
            initialFreeSpace=$(grep "^$sourceDisk " "$tempFile" | awk '{print $2}')
            echo "  $sourceDisk (Available free space: $(formatSpace $initialFreeSpace), Target: $(formatSpace $minFreeDiskSpace))" >> "$dryRunFilePath"
            echo "    Moves:" >> "$dryRunFilePath"
        fi

        for rootFolder in "${rootFolders[@]}"; do
            rootFolderPath="$diskPath/$sourceDisk/$rootFolder"

            if [ ! -d "$rootFolderPath" ]; then
                logMessage "debug,info" "    Root folder $rootFolderPath not found on $sourceDisk"
                continue
            fi

            sourceDirectories=()
            while IFS= read -r dir; do
                sourceDirectories+=("$dir")
            done < <(find "$rootFolderPath" -maxdepth 1 -mindepth 1 -type d)

            if [ ${#sourceDirectories[@]} -eq 0 ]; then
                logMessage "info" "    No directories found on $sourceDisk for transfer."
                continue
            fi

            getSortKey() {
                local dir="$1"
                case "$moverMode" in
                    "largest" | "smallest") du -s "$dir" | awk '{print $1}' ;;
                    "oldest" | "newest") stat -c %W "$dir" 2>/dev/null || stat -c %Y "$dir" ;;
                    *) echo "$dir" ;;
                esac
            }

            if [[ "$moverMode" == "largest" || "$moverMode" == "smallest" || "$moverMode" == "oldest" || "$moverMode" == "newest" ]]; then
                readarray -t sourceDirectories < <(for dir in "${sourceDirectories[@]}"; do
                    if [[ " ${missingDirectories[@]} " =~ " $dir " ]]; then
                        continue
                    fi
                    
                    echo "$(getSortKey "$dir") $dir"
                done | sort -k1,1n | awk '{print substr($0, index($0,$2))}')
            fi

            if [[ "$moverMode" == "largest" || "$moverMode" == "newest" ]]; then
                readarray -t sourceDirectories < <(printf "%s\n" "${sourceDirectories[@]}" | tac)
            fi

            freeSpace=$(grep "^$sourceDisk " "$tempFile" | awk '{print $2}')
            logMessage "debug" "    Free space on source disk ($sourceDisk) is $(formatSpace $freeSpace)"

            if [ "$dryRun" == "true" ]; then
                unset dataMovedTargetDisks
                declare -A dataMovedTargetDisks
            fi

            for sourceDir in "${sourceDirectories[@]}"; do
                sourceDirSize=$(du -sm "$sourceDir" 2>/dev/null | awk '{print $1}')
                if [ -z "$sourceDirSize" ]; then
                    missingDirectories+=("$sourceDir")
                    logMessage "warn" "    Directory $sourceDir cannot be accessed and will be added to missing directories."
                    continue
                fi

                targetDisk=$(findLeastFreeDisk "$sourceDirSize" "$tempFile")
                if [ -z "$targetDisk" ]; then
                    logMessage "error" "    No destination disk found for $sourceDir (size: $(formatSpace $sourceDirSize))"
                    continue
                fi

                targetDiskFreeSpace=$(grep "^$targetDisk " "$tempFile" | awk '{print $2}')
                logMessage "debug" "    Free space on target disk ($targetDisk) is $(formatSpace $targetDiskFreeSpace)"

                targetDir=$(echo "$sourceDir" | sed "s|^$diskPath/disk[0-9]\+|$diskPath/$targetDisk|")

                if [ "$dryRun" == "true" ]; then
                    echo "      \"$sourceDir\" ($(formatSpace $sourceDirSize))" >> "$dryRunFilePath"
                    echo "       ➥ \"$targetDir\"" >> "$dryRunFilePath"
                else
                    echo "$sourceDirSize \"$sourceDir\" \"$targetDir\"" >> "$moveListFile"
                fi

                logMessage "debug,info" "    Queued move: $sourceDir ($(formatSpace $sourceDirSize)) → $targetDisk"

                updateFreeSpace "$sourceDisk" "$sourceDirSize" "$tempFile"
                updateFreeSpace "$targetDisk" "$((-sourceDirSize))" "$tempFile"

                sourceDiskfreeSpace=$(grep "^$sourceDisk " "$tempFile" | awk '{print $2}')
                logMessage "debug" "    Updated free space on source disk ($sourceDisk) is $(formatSpace $sourceDiskfreeSpace)"

                targetDiskFreeSpace=$(grep "^$targetDisk " "$tempFile" | awk '{print $2}')
                logMessage "debug" "    Updated free space on target disk ($targetDisk) is $(formatSpace $targetDiskFreeSpace)"

                if [ "$dryRun" == "true" ]; then
                    totalDataMovedSourceDisks[$sourceDisk]=$((totalDataMovedSourceDisks[$sourceDisk] + sourceDirSize))
                    totalDataMovedTargetDisks[$targetDisk]=$((totalDataMovedTargetDisks[$targetDisk] + sourceDirSize))
                    dataMovedTargetDisks[$targetDisk]=$((dataMovedTargetDisks[$targetDisk] + sourceDirSize))
                fi

                if [ "$sourceDiskfreeSpace" -ge "$maxSourceDiskFreeSpace" ]; then
                    logMessage "debug" "    Free space on source disk ($sourceDisk) exceeds minimum threshold."
                    break
                else
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

    if [ "$dryRun" == "true" ]; then
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
        if [[ $line =~ ^([0-9]+)\ [\"']([^\"]+)[\"']\ [\"']([^\"]+)[\"']$ ]]; then
            sourceDirSize="${BASH_REMATCH[1]}"
            sourceDir="${BASH_REMATCH[2]}"
            targetDir="${BASH_REMATCH[3]}"
            targetDisk=$(echo "$targetDir" | awk -F'/' '{print $3}')
        else
            logMessage "error" "Failed to parse line: $line"
            continue
        fi

        if [ ! -d "$sourceDir" ]; then
            logMessage "error" "Source directory $sourceDir does not exist. Skipping move."
            continue
        fi

        rsync -avz --remove-source-files --progress -- "$sourceDir/" "$targetDir/" &

        find "$sourceDir" -type d -empty -exec rmdir {} \;

        while [ "$(jobs -r | wc -l)" -ge "$fileTransferLimit" ]; do
            sleep 1
        done
    done < "$moveListFile"

    wait
}

main() {
    initializeLogs
    initializeDryRun
    validateConfiguration
    
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

        freeSpace=$(getFreeSpace "$disk")

        logMessage "debug" "    $disk: $(formatSpace $freeSpace)"
        if [ "$freeSpace" -lt "$minFreeDiskSpace" ]; then
            sourceDisks["$disk"]=$freeSpace
            logMessage "info" "  Adding $disk to source disks due to low free space"
        else
            targetDisks["$disk"]=$freeSpace
            logMessage "info" "  Adding $disk to target disks"
        fi
    done
    
    if [ ${#sourceDisks[@]} -eq 0 ]; then
        logMessage "info" "No source disks require maintenance."
        exit 1
    fi

    logMessage "debug" "  Analyzing disks..."

    sortedNameSourceDisks=($(for disk in "${!sourceDisks[@]}"; do echo "$disk"; done | sort -V))
    sortedNameTargetDisks=($(for disk in "${!targetDisks[@]}"; do echo "$disk"; done | sort -V))

    logMessage "debug" "    Source disks: ${sortedNameSourceDisks[@]}"
    logMessage "debug" "    Target disks: ${sortedNameTargetDisks[@]}"

    echo "Disks:" >> "$dryRunFilePath"
    echo "  Source: ${sortedNameSourceDisks[@]}" >> "$dryRunFilePath"
    echo "  Target: ${sortedNameTargetDisks[@]}" >> "$dryRunFilePath"
    echo "" >> "$dryRunFilePath"

    tempFile=$(mktemp "$scriptDir/tmp.XXXXXX")

    find "$scriptDir" -name 'tmp.*' -type f -exec rm -f {} \;

    initializeTempFile "$tempFile"

    missingDirectories=()

    declare -A movedDirectories
    declare -A movedData

    moveListFile=$(mktemp)
    generateMoveList "$moveListFile"

    if [ "$dryRun" == "true" ]; then
        logMessage "debug,info" "Simulation mode: Transfer plan saved to $dryRunFilePath."

        exit 0
    elif [ "$logLevel" == "debug" ]; then
        logMessage "debug,info" "Debug mode: Transfer plan saved to $dryRunFilePath."
        cp "$moveListFile" "$fileListFilePath"
    fi

    moveFilesFromList "$moveListFile"

    logMessage "debug" "Waiting for all background jobs to complete..."
    wait

    logMessage "debug" "Missing directories:"
    if [ ${#missingDirectories[@]} -gt 0 ]; then
        logMessage "debug,warn" "Missing Directories:"
        for missingDir in "${missingDirectories[@]}"; do
            logMessage "debug,warn" "  $missingDir"
        done
    fi

    if [ "$dryRun" != "true" ] && [ "$logLevel" != "debug" ]; then
        rm -f "$tempFile"
    fi

    logMessage "info" "Movarr is done."
    logMessage "debug" "movarr.sh script completed."

    addFooter
}

if isMovarrRunning; then
    logMessage "debug,info" "movarr.sh is already running. Exiting."
    exit 0
fi

logMessage "debug,info" "movarr.sh script started."

main

logMessage "debug" "Cleaning up PID file"
rm -f "$scriptDir/movarr.pid"