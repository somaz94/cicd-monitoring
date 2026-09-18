# Harbor Image Cleanup Scripts

A collection of scripts for cleaning up old images from a Harbor registry.

<br/>

## Script Structure

<br/>

### Two parallel sets

There are two entry scripts, `harbor-image-cleanup.sh` and `harbor-image-cleanup-en.sh`, and the statistics helper is paired the same way as `stats-help.sh` / `stats-help-en.sh`. The feature modules under `modules/` come in the same two sets.

The two sets are separated by lineage, not by language. Neither one emits Korean; they differ in which module set the entry script sources (`modules/*.sh` versus `modules/*-en.sh`) and in message wording and capitalisation. For how far apart the two sets actually are right now, `diff` is the answer.

```bash
diff harbor-image-cleanup.sh harbor-image-cleanup-en.sh
diff modules/harbor-utils.sh modules/harbor-utils-en.sh
```

<br/>

## Module Descriptions

### 1. harbor-config.sh / harbor-config-en.sh
- Global variable definitions
- Command-line argument parsing
- Configuration validation
- Help display

### 2. harbor-utils.sh / harbor-utils-en.sh
- Debug output functions
- Delete confirmation functions
- Harbor API version check
- Startup information display

### 3. harbor-repository.sh / harbor-repository-en.sh
- Repository listing
- Repository information retrieval
- Artifact count calculation

### 4. harbor-image.sh / harbor-image-en.sh
- Image tag retrieval
- Image deletion
- Batch processing

### 5. harbor-project-stats.sh / harbor-project-stats-en.sh
- Per-repository artifact statistics by project
- Artifact count calculation and display
- Color-coded display

<br/>

## Usage

### Basic Usage
```bash
# Either entry script takes the same options
./harbor-image-cleanup.sh [options]
./harbor-image-cleanup-en.sh [options]
```

<br/>

### Options

- `-h, --help`: Show this help message and exit
- `-d, --debug`: Enable debug mode
- `--dry-run`: Don't actually delete images, just print what would be deleted
- `--auto-confirm`: Skip confirmation and automatically delete images
- `-k, --keep N`: Keep the newest N images (default: 100)
- `-p, --project NAME`: Harbor project name (default: example-project)
- `-r, --repo NAME`: Repository name. Can be specified multiple times. Use 'all' to process all repositories
- `-b, --batch-size N`: Number of images to delete in parallel (default: 10)
- `--stats PROJECT`: Show artifact counts by repository for a specific project

<br/>

### Usage Examples

```bash
# Dry run test
./harbor-image-cleanup.sh --dry-run -k 50 -p myproject -r myrepo

# Clean specific repositories
./harbor-image-cleanup.sh -p myproject -r repo1 -r repo2 -k 20 --auto-confirm

# Clean all repositories in project
./harbor-image-cleanup.sh -p myproject -r all -k 50

# Show project statistics
./harbor-image-cleanup.sh --stats example-project

# Show statistics help
./stats-help.sh
```

The `-en.sh` variant takes the same options and the same arguments.

<br/>

## Project Statistics Feature

A statistics feature has been added to view artifact counts per repository in a Harbor project.

### Feature Overview
- View artifact counts for all repositories in a specific project
- Color-coded by artifact count (Red: over 100, Yellow: 11-100, Green: 10 or less)
- Last update time display
- Summary statistics (total repositories, total artifacts, average artifacts)

### Usage

#### Statistics via Main Script
```bash
./harbor-image-cleanup.sh --stats <project-name>
./harbor-image-cleanup-en.sh --stats <project-name>
```

#### Standalone Statistics Help Script
```bash
./stats-help.sh
./stats-help-en.sh
```

### Output Example
```
=== Artifact counts by repository for project 'example-project' ===

No.  Repository Name                          Artifact Count  Last Updated
---- ---------------------------------------- --------------- --------------------
1    app-admin                                54              2025-07-16 03:34:17
2    app-admin/cache                          80              2025-07-16 03:32:27
3    battle                                   31              2025-05-15 03:49:31
4    battle/cache                             51              2025-04-16 08:45:50
5    admin                                    101             2025-07-16 08:20:18
6    admin/cache                              104             2025-07-16 08:17:38
7    game                                     101             2025-07-16 08:20:18
8    game/cache                               103             2025-07-16 08:17:38

=== Summary ===
Total Repositories: 8
Total Artifacts: 625
Average Artifacts per Repository: 78
```

<br/>

## Benefits of Modularization

1. **Improved Readability**: Splitting the single-file predecessor into functional modules makes it easier to read
2. **Maintainability**: Easier to modify or extend specific features
3. **Reusability**: Individual modules can be used in other scripts
4. **Testability**: Each module can be independently tested
5. **Better Collaboration**: Multiple developers can work on different modules simultaneously

<br/>

## Setting Execution Permissions

Before running the scripts, you must grant execution permissions:

```bash
chmod +x *.sh modules/*.sh
```

<br/>

## Important Notes

- Harbor server access credentials are required
- `curl` and `jq` commands must be installed
- In production environments, test with the `--dry-run` option first
- Deleted images cannot be recovered, so use with caution

<br/>

## Configuration

Default configuration values are edited in the config module the entry script sources — `modules/harbor-config.sh` and `modules/harbor-config-en.sh` carry the same keys.

- `DEFAULT_HARBOR_URL`: Harbor server URL
- `DEFAULT_HARBOR_USER`: Harbor username
- `DEFAULT_HARBOR_PASS`: Harbor password
- `DEFAULT_PROJECT_NAME`: Default project name
- `DEFAULT_IMAGES_TO_KEEP`: Default number of images to keep

<br/>

## Which one to run

Both sets do the same job, so either is fine — but stay with the one you pick: the wording differs, which makes logs and screenshots awkward to compare. When wiring one into automation, do not mix an entry script with the other module set; each entry script sources only its own.
