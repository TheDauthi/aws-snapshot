#!/usr/bin/env bash

if [[ -z "${AWS_CONFIG_PATH}" ]]; then
  AWS_CONFIG_PATH="$(cd -P -- "$(dirname -- "$0")" && pwd -P)"
fi

if [[ -z "${AWS_CONFIG}" ]]; then
  AWS_CONFIG="${AWS_CONFIG_PATH}/.config"
fi

if [[ -f "${AWS_CONFIG}" ]]; then
  . "${AWS_CONFIG}"
fi

DEFAULT_TAGS="${DEFAULT_TAGS-CreatedBy=AutomatedBackup}"
VOLUMES=()
INSTANCES=()
TAGLIST=()
TAGMAP=()
SNAPSHOT_FILTERS=()
FROZEN_MOUNTS=()

MAX_AGE=${MAX_AGE:-'- 7 days'}
MAX_DATE=${MAX_DATE:-}
DEBUG='1'

export AWS_DEFAULT_OUTPUT=text

declare -A VOLUME_TAGS
declare -A SNAPSHOT_TAGS

EXTRA_TAG_LIST="${DEFAULT_TAGS}"

__parse_commandline() {
  POSITIONAL=()
  while [[ "$1" != "" ]]; do
    case $1 in
      --help | -h)
        usage
        exit
        ;;
      --volume | --volumes | -v)
        VOLUMES+=("$2")
        shift
        ;;
      --no-max-date)
        MAX_DATE=0
        ;;
      --instance | -i)
        INSTANCES+=("$2")
        shift
        ;;
      --tag-list | --tags)
        TAGLIST+=("$2")
        shift
        ;;
      --snapshot-tag-filter)
        SNAPSHOT_FILTERS+=("$2")
        shift
        ;;
      --tag-map)
        TAGMAP+=("$2")
        shift
        ;;
      --extra-tags)
        EXTRA_TAG_LIST="${DEFAULT_TAGS} $2"
        shift
        ;;
      --max-age)
        MAX_AGE="$2"
        shift
        ;;
      --max-date)
        MAX_DATE="$2"
        shift
        ;;
      --dry-run | -d)
        DRY_RUN='--dry-run'
        ;;
      --debug)
        DEBUG=1
        ;;
      --freeze)
        FREEZE=1
        ;;
      * )
        POSITIONAL+=("$1")
        ;;
    esac
    shift
  done
}

####
# Parses "MAX_AGE" or "MAX_DATE" into the min epoch time to keep
__parse_retention_date() {
  # If max-date is set, just convert it to epoch
  # Otherwise, we need to parse from the "max age"
  # We want to accept: 6 6D '6 days'
  if [[ ! -z "${MAX_DATE}" ]]; then
    MAX_DATE=$(date +%s --date "${MAX_DATE}")
  elif [[ "${MAX_AGE}" =~ ^[0-9]+$ ]]; then
    MAX_DATE=$(date +%s --date "${MAX_AGE} days ago")
  elif [[ "${MAX_AGE}" =~ ^[0-9]+[dD]$ ]]; then
    MAX_AGE="${MAX_AGE//[^0-9]/}"
    MAX_DATE=$(date +%s --date "${MAX_AGE} days ago")
  elif [[ "${MAX_AGE}" =~ ^[0-9]+[wW]$ ]]; then
    MAX_AGE="${MAX_AGE//[^0-9]/}"
    MAX_DATE=$(date +%s --date "${MAX_AGE} weeks ago")
  elif [[ "${MAX_AGE}" =~ ^[0-9]+[mM]$ ]]; then
    MAX_AGE="${MAX_AGE//[^0-9]/}"
    MAX_DATE=$(date +%s --date "${MAX_AGE} months ago")
  elif [[ "${MAX_AGE}" =~ ^[0-9]+[yY]$ ]]; then
    MAX_AGE="${MAX_AGE//[^0-9]/}"
    MAX_DATE=$(date +%s --date "${MAX_AGE} years ago")
  else
    # Well, hopefully 'date' can get-er-done
    MAX_DATE=$(date +%s --date "${MAX_AGE}")
  fi
}

###
# Simple logging
log() {
  >&2 echo "[$(date +"%Y-%m-%d"+"%T")]: $*"
}

###
# Log only if debug is set
debug() {
  if [[ ! -z "${DEBUG}" ]]; then
    >&2 log "$*"
  fi
}

__get_local_aws_id() {
  # curl http://169.254.169.254/latest/meta-data/instance-id
  echo i-03be67efc82c8c1e3
}

__is_ec2() {
  if [[ -e /sys/hypervisor/uuid && $(cat /sys/hypervisor/uuid) =~ "ec2*" ]] && $(curl http://169.254.169.254/latest/meta-data/instance-id); then
    return 0
  else
    return 1
  fi
}

####################################
######### Volume Freezing ##########
####################################
__get_local_filesystems() {
  __get_volumes_for_instance "$(__get_local_aws_id)"
}

__fsfreeze_volumes() {
  volume=$1
  device=$2
  if __is_ec2; then
    if [[ ! -z "${FREEZE}" && "$(__get_local_filesystems)" == *"${volume}"* ]]; then
      mount_target=$(__get_mount_target "${device}")
      FROZEN_MOUNTS+=("${mount_target}")
      debug "would freeze the device ${device} at ${mount_target}"
    fi
  fi
}

__get_mount_target() {
  device=$1
  findmnt -o TARGET "${device}"
}

__unfsfreeze_volume() {
  device=$1
  mount_target=$(__get_mount_target "${device}")
  
  if [[ " ${FROZEN_MOUNTS[@]} " =~ " ${mount_target} " ]]; then
    debug "Unfreezing ${mount_target}"
    fsfreeze --unfreeze "${mount_target}"
  fi
}

__unfsfreeze_all() {
  for mount_target in "${FROZEN_MOUNTS[@]}"; do
    debug "Unfreezing ${mount_target}"
    fsfreeze --unfreeze "${mount_target}"
  done  
}

###
# Get a list of instances from AWS if not explicitly specified
__get_instance_list() {
  if [[ "${#INSTANCES[@]}" -eq "0" && "${#VOLUMES[@]}" -eq "0" ]]; then
    instance_list=$(aws ec2 describe-instances --query 'Reservations[].Instances[].InstanceId')
    INSTANCES=($instance_list)
  fi
}

__get_volumes_for_instance() {
  instance="$1"
  aws ec2 describe-volumes --filters "Name=attachment.instance-id,Values='${instance}'" --query 'Volumes[].VolumeId' --output text
}

###
# Get a list of volumes from AWS if not explicitly specified
__get_volumes_for_instances() {
  for instance in "${INSTANCES[@]}"; do
    debug "Getting volumes for '${instance}'"
    volume_list=$(__get_volumes_for_instance "${instance}")
    volume_list=($volume_list)

    for volume in "${volume_list[@]}"; do
      debug "Found volume ${volume} for ${instance}"
    done

    VOLUMES+=( "${volume_list[@]}" )
  done
}

__read_volume_tags() {
  volume="$1"

  VOLUME_TAGS=()
  tags=$(aws ec2 describe-volumes --volume-ids "${volume}" --query 'Volumes[0].Tags' --output text)

  while read -r key value; do
    VOLUME_TAGS[$key]=$value
  done <<< "${tags}"
}

__read_snapshot_tags() {
  snapshot_id="$1"

  SNAPSHOT_TAGS=()
  tags=$(aws ec2 describe-snapshots --snapshot-ids "${snapshot_id}" --query 'Snapshots[0].Tags' --output text)

  while read -r key value; do
    SNAPSHOT_TAGS[$key]=$value
  done <<< "${tags}"
}

###
# Given a list of volumes, filter out any not matching tags given on the command line
__filter_volume_by_tag() {
  volume="$1"

  # We're good if we're not filtering by tags
  if [[ "${#TAGLIST[@]}" -eq "0" ]]; then
    return 1
  fi

  for tag in "${TAGLIST[@]}"; do
    IFS='=' read -r key value <<< "${tag}"
    if [[ "${VOLUME_TAGS[$key]}" ]]; then
      if [[ -z "${value}" ]] || [[ "${VOLUME_TAGS[$key]}" == "${value}" ]]; then
        return 1
      fi
    fi
  done

  return 0
}

###
# Given a list of snapshots, filter out any not matching tags given on the command line
__filter_snapshot_by_tags() {
  snapshot="$1"

  # We're good if we're not filtering by tags
  if [[ "${#SNAPSHOT_FILTERS[@]}" -eq "0" ]]; then
    return 1
  fi

  for tag in "${SNAPSHOT_FILTERS[@]}"; do
    IFS='=' read -r key value <<< "${tag}"
    if [[ "${SNAPSHOT_TAGS[$key]}" ]]; then
      if [[ -z "${value}" ]] || [[ "${SNAPSHOT_TAGS[$key]}" == "${value}" ]]; then
        return 1
      fi
    fi
  done

  return 0
}

###
# During cleanup, snapshots must have -all- default tags.
__filter_snapshot_by_required_tags() {
  for tag in $EXTRA_TAG_LIST; do
    IFS='=' read -r key value <<< "${tag}"
    if [[ -z "${SNAPSHOT_TAGS[$key]}" ]]; then
      return 0
    fi
  done
  return 1
}

__get_volume_data() {
  volume="$1"
  aws ec2 describe-volumes --output=text --volume-ids "${volume}" --query 'Volumes[0].Attachments[0].[InstanceId,Device]'
}

__build_name_for_volume() {
  instance_name="$1"
  device_name="$2"
  snapshot_tag="[${instance_name}]-[${device_name}]-backup-[$(date +'%Y-%m-%d %H:%M:%S')]"
  echo "${snapshot_tag}"
}

__add_tag_to_snapshot() {
  snapshot_id="$1"
  tag_name="$2"
  tag_value="$3"

  aws ec2 create-tags --resource "${snapshot_id}" --tags "Key='${tag_name}',Value='${tag_value}'"
}

###
# tagmaps copy "volume:tag" to "snapshop:tag"
# The values copied match "volume_tag=snapshot_tag" or "tag_to_copy"
__add_tagmap_to_snapshot() {
  volume="$1"
  snapshot_id="$2"

  for tag in "${TAGMAP[@]}"; do
    IFS='=' read -r key value <<< "${tag}"
    tag_key="${value:-$key}"
    tag_value="${VOLUME_TAGS[$key]}"
    
    if [[ -z "${tag_value}" ]]; then
      log "Not copying empty value from tag '${volume}:${tag_key}'"
      continue
    fi

    log "Adding '${tag_key}' to '${snapshot_id}' as '${tag_value}'"

    __add_tag_to_snapshot "${snapshot_id}" "${tag_key}" "${tag_value}"
  done
}

__create_snapshot() {
  name="$1"
  volume="$2"
  aws ec2 create-snapshot --output=text --description "${name}" --volume-id "${volume}" --query 'SnapshotId'
}

__add_extra_tags_to_snapshot() {
  snapshot="$1"
  for tag in $EXTRA_TAG_LIST; do
    IFS='=' read -r key value <<< "${tag}"
    __add_tag_to_snapshot "${snapshot}" "${key}" "${value}"
  done
}

__make_snapshot_for_volume() {
  volume="$1"

  volume_data=$(__get_volume_data "${volume}")

  read -r instance_name device_name <<< "${volume_data}"

  name=$(__build_name_for_volume "${instance_name}" "${device_name}")

  __fsfreeze_volumes "${volume}" "${device_name}"

  snapshot_id=$(__create_snapshot "${name}" "${volume}")

  __unfsfreeze_volume "${device_name}"

  __add_extra_tags_to_snapshot "${snapshot_id}" 
  __add_tagmap_to_snapshot "${volume}" "${snapshot_id}"
}

###
# Creates snapshots of all known volumes
__snapshot_volumes() {
  for volume in "${VOLUMES[@]}"; do
    log "Discovered volume $volume"

    __read_volume_tags "${volume}"

    if __filter_volume_by_tag "${volume}"; then
      log "${volume} was discovered but filtered via tag"
      continue
    fi

    log "Snapshotting $volume..."
    
    if [[ ! -z "${DRY_RUN}" ]]; then
      debug "dry-run enabled, skipping real work"
      continue
    fi
    
    __make_snapshot_for_volume "${volume}"
  done  
}

__filter_snapshot_by_date() {
  snapshot="$1"
  snapshot_date=$(aws ec2 describe-snapshots --output=text --snapshot-ids "${snapshot}" --query Snapshots[].StartTime)
  snapshot_date_epoch=$(date -d "${snapshot_date}" +'%s')

  if (( $snapshot_date_epoch <= $MAX_DATE )); then
    return 1;
  else
    return 0;
  fi
}

__remove_snapshot() {
  snapshot="$1"
  if [[ ! -z "${DRY_RUN}" ]]; then
    debug "... skipping actual delete due to dry-run"
  else
    aws ec2 delete-snapshot --snapshot-id "${snapshot}"
  fi
}

__cleanup_snapshots_for_volume() {
  volume_id="$1"
  
  debug "Beginning check of volume: '${volume_id}'"
  
  snapshot_list=$(__get_snapshots_for_volume "${volume_id}")
  
  for snapshot in $snapshot_list; do
    debug "Beginning check of ${snapshot}"
    __read_snapshot_tags "${snapshot}"

    if __filter_snapshot_by_required_tags "${snapshot}"; then
      debug "'${snapshot}' was discovered but is missing a required tag"
      continue
    fi

    if __filter_snapshot_by_tags "${snapshot}"; then
      debug "'${snapshot}' was discovered but filtered by tag"
      continue
    fi
    if __filter_snapshot_by_date "${snapshot}"; then
      debug "'${snapshot}' was discovered but filtered by date"
      continue
    fi
    debug "Will remove snapshot '${snapshot}'"
    __remove_snapshot "${snapshot}"
  done
}

__get_snapshots_for_volume() {
  volume_id="$1"
  aws ec2 describe-snapshots --output=text --filters "Name=volume-id,Values='${volume_id}'" --query 'Snapshots[].SnapshotId'
}

__cleanup_volumes() {
  for volume in "${VOLUMES[@]}"; do
    __cleanup_snapshots_for_volume "${volume}"
  done
}

finish() {
  __unfsfreeze_all
}

usage() {
  cat <<HELP_USAGE

  $0  [options] ... command

Commands:
  backup                 Takes snapshots of volumes matching the given filters
  cleanup                Cleans up old snapshots
  cycle                  Performs snapshots, then runs cleanup

[all]
  --help                 Shows the help message
  --volume               An explicit list of volumes to operate on
  --instance             List of instances to check for volumes
  --tag-list             List of tags to check volumes for snapshotting
  --dry-run              Don't actually do anything!
  --debug                Show debug output

[backup]
  Takes a snapshot of a list of volumes. The list of volumes can be given via --volume,
  or found by searching AWS volumes.
  --tag-map              List of tags to clone from volume to snapshot

[cleanup]
  Cleans the snapshot list, removing snapshots older than the given age or date (default: 7 days)
  --snapshot-tag-filter  List of tags to filter on volumes during snapshot cleanup
  --max-age              Maxiumum age of snapshots to keep
  --max-date             Maximum date of snapshot to keep
  --no-max-date          Do not filter by dates at all (equal to --max-date=0)

HELP_USAGE
}

trap finish EXIT

__snapshot() {
  __get_instance_list
  __get_volumes_for_instances

  # __snapshot_volumes
  __get_local_filesystems
}

__cleanup() {
  __parse_retention_date
  __get_instance_list
  __get_volumes_for_instances
  __cleanup_volumes
}

__cycle() {
  __parse_retention_date
  __get_instance_list
  __get_volumes_for_instances
  __snapshot_volumes
  __cleanup_volumes
}

__parse_commandline "$@"

COMMAND="${POSITIONAL[0]}"

if [[ "${COMMAND}" == "backup" ]]; then
  __snapshot
elif [[ "${COMMAND}" == "cleanup" ]]; then
  __cleanup
elif [[ "${COMMAND}" == "cycle" ]]; then
  __cycle
else
  echo "Unknown command: must give one of [backup,cleanup,cycle]"
fi

