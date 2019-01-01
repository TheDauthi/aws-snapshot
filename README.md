# aws-snapshot
Creates and Rotates EBS snapshots

# Usage

snap.sh  [options] ... command

Commands:
  snapshot               Takes a snapshot of volumes matching the given filters
  cleanup                Cleans up old snapshots
  maintain               Performs snapshots, then runs cleanup

[all]
  --help                 Shows the help message
  --volume               An explicit list of volumes to operate on
  --instance             List of instances to check for volumes
  --tag-list             List of tags to check volumes for snapshotting
  --dry-run              Don't actually do anything!
  --debug                Show debug output

[snapshot]
  Takes a snapshot of a list of volumes. The list of volumes can be given via --volume,
  or found by searching AWS volumes.
  --tag-map              List of tags to clone from volume to snapshot

[cleanup]
  Cleans the snapshot list, removing snapshots older than the given age or date (default: 7 days)
  --snapshot-tag-filter  List of tags to filter on volumes during snapshot cleanup
  --max-age              Maxiumum age of snapshots to keep
  --max-date             Maximum date of snapshot to keep
  --no-max-date          Do not filter by dates at all (equal to --max-date=0)

## Tag Matching
Tags are matched in a case-sensitive manner. Tags can be matched by key existence (`--tag-list key_name`) or by key-value (`--tag-list key_name=value`). Multiple tags are supported, but multiple values for the same tag are currently not.

## Volume Discovery
The volume discovery algorithm works like this:

- If nothing is passed on the command line, discover all instances and all volumes attached to those instances.
- If a list of instances is passed, add all volumes for those instances to the discovery list.
- If a list of volumes is passed, add the given volumes to the discovery list.

Finally, if tags are given via `--tag-list`, remove any item that does not match at least one of the tag keys or key-values given.

## Tag Maps
If a tag map is given, the value of the tag is copied from the volume to the newly-created snapshot. A new name for the tag may be given as a key-value pair.

## Config File
A config file can be given via an `AWS_CONFIG` environment variable.
