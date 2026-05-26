# Harbor Image Cleanup Scripts

A collection of scripts for cleaning up old images from a Harbor registry.

<br/>

## Script Structure

<br/>

### Original Script
- `backup/harbor-image-cleanup.sh`: Original single-file script (1338 lines)

### Modularized Scripts

Naming convention: `<name>.sh` is Korean (default), `<name>-en.sh` is the English variant. Same pattern as README files.

#### Korean Version (default)
- `harbor-image-cleanup.sh`: Korean main execution script
- `modules/`: Korean functionality modules

#### English Version
- `harbor-image-cleanup-en.sh`: English main execution script
- `modules/*-en.sh`: English functionality modules

```bash
cicd/harbor-helm/scripts/image-cleanup/
├── harbor-image-cleanup.sh                 # Modularized main script (Korean, default)
├── harbor-image-cleanup-en.sh              # Modularized main script (English)
├── stats-help.sh                           # Statistics help script (Korean, default)
├── stats-help-en.sh                        # Statistics help script (English)
├── modules/
│   ├── harbor-config.sh                    # Configuration management (Korean)
│   ├── harbor-config-en.sh                 # Configuration management (English)
│   ├── harbor-utils.sh                     # Utility functions (Korean)
│   ├── harbor-utils-en.sh                  # Utility functions (English)
│   ├── harbor-auth.sh                      # Authentication management (Korean)
│   ├── harbor-auth-en.sh                   # Authentication management (English)
│   ├── harbor-repository.sh                # Repository management (Korean)
│   ├── harbor-repository-en.sh             # Repository management (English)
│   ├── harbor-image.sh                     # Image management (Korean)
│   ├── harbor-image-en.sh                  # Image management (English)
│   ├── harbor-project-stats.sh             # Project statistics (Korean)
│   └── harbor-project-stats-en.sh          # Project statistics (English)
├── backup/
│   └── harbor-image-cleanup.sh             # Original single-file script (1338 lines, legacy)
└── README.md
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

### 3. harbor-auth.sh / harbor-auth-en.sh
- Harbor authentication token acquisition

### 4. harbor-repository.sh / harbor-repository-en.sh
- Repository listing
- Repository information retrieval
- Artifact count calculation

### 5. harbor-image.sh / harbor-image-en.sh
- Image tag retrieval
- Image deletion
- Batch processing

### 6. harbor-project-stats.sh / harbor-project-stats-en.sh
- Per-repository artifact statistics by project
- Artifact count calculation and display
- Color-coded display

<br/>

## Usage

### Basic Usage
```bash
# Run Korean modularized script (default)
./harbor-image-cleanup.sh [options]

# Run English modularized script
./harbor-image-cleanup-en.sh [options]

# Run original single-file script (legacy, in backup/)
./backup/harbor-image-cleanup.sh [options]
```

<br/>

### Options

#### English Version
- `-h, --help`: Show this help message and exit
- `-d, --debug`: Enable debug mode
- `--dry-run`: Don't actually delete images, just print what would be deleted
- `--auto-confirm`: Skip confirmation and automatically delete images
- `-k, --keep N`: Keep the newest N images (default: 100)
- `-p, --project NAME`: Harbor project name (default: example-project)
- `-r, --repo NAME`: Repository name. Can be specified multiple times. Use 'all' to process all repositories
- `-b, --batch-size N`: Number of images to delete in parallel (default: 10)
- `--stats PROJECT`: Show artifact counts by repository for a specific project

#### Korean Version
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

#### English Version
```bash
# Dry run test
./harbor-image-cleanup-en.sh --dry-run -k 50 -p myproject -r myrepo

# Clean specific repositories
./harbor-image-cleanup-en.sh -p myproject -r repo1 -r repo2 -k 20 --auto-confirm

# Clean all repositories in project
./harbor-image-cleanup-en.sh -p myproject -r all -k 50

# Show project statistics
./harbor-image-cleanup-en.sh --stats example-project

# Show statistics help
./stats-help-en.sh
```

#### Korean Version
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
# English version
./harbor-image-cleanup-en.sh --stats <project-name>

# Korean version
./harbor-image-cleanup.sh --stats <project-name>
```

#### Standalone Statistics Help Script
```bash
# English version help
./stats-help-en.sh

# Korean version help
./stats-help.sh
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

1. **Improved Readability**: Splitting a 1338-line single file into functional modules makes it easier to understand
2. **Maintainability**: Easier to modify or extend specific features
3. **Reusability**: Individual modules can be used in other scripts
4. **Testability**: Each module can be independently tested
5. **Better Collaboration**: Multiple developers can work on different modules simultaneously
6. **Multi-language Support**: Easy management of English and Korean versions

<br/>

## Setting Execution Permissions

Before running the scripts, you must grant execution permissions:

```bash
# Korean version (default)
chmod +x harbor-image-cleanup.sh
chmod +x stats-help.sh
chmod +x modules/harbor-*.sh

# English version
chmod +x harbor-image-cleanup-en.sh
chmod +x stats-help-en.sh
chmod +x modules/harbor-*-en.sh

# Original script (legacy)
chmod +x backup/harbor-image-cleanup.sh

# Set all permissions at once (convenient)
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

Default configuration values can be modified in the corresponding config module:

### Korean Version (default): `modules/harbor-config.sh`
- `DEFAULT_HARBOR_URL`: Harbor server URL
- `DEFAULT_HARBOR_USER`: Harbor username
- `DEFAULT_HARBOR_PASS`: Harbor password
- `DEFAULT_PROJECT_NAME`: Default project name
- `DEFAULT_IMAGES_TO_KEEP`: Default number of images to keep

### English Version: `modules/harbor-config-en.sh`
- `DEFAULT_HARBOR_URL`: Harbor server URL
- `DEFAULT_HARBOR_USER`: Harbor username
- `DEFAULT_HARBOR_PASS`: Harbor password
- `DEFAULT_PROJECT_NAME`: Default project name
- `DEFAULT_IMAGES_TO_KEEP`: Default number of images to keep

<br/>

## Selection Guide

- **Original Script**: When you want to maintain the existing approach
- **English Modularized Script**: For international environments, leveraging the benefits of modularization
- **Korean Modularized Script**: For Korean environments, leveraging the benefits of modularization
