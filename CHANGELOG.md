# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.1.3] - 2026-05-28

### Changed
- Secret authentication to certificate authentication

## [2.0.3] - 2026-05-15

### Added
- GitHub Actions workflows for automated release creation and changelog verification

### Fixed
- Use GUID property instead of object references for distribution group identification to improve stability and consistency.

## [2.0.2] - 2026-01-30

### Fixed
- Set managerCanOverrideDuration default to false (#4)

## [2.0.1] - 2025-05-28

### Fixed
- Corrected verbose logging -eq true to write-verbose (#2)

## [2.0.0] - 2025-03-21

### Added
- Compatible with new tasks (#1)

### Changed
- Major version bump due to compatibility updates

## [1.0.0] - 2024-01-15

### Added
- Initial release with all core functionality

## Pre-release Changes

### [2023-01-30]

### Changed
- Changed new-object to ::new() for better performance

### [2022-07-26]

### Added
- Support for commentOption and returnOnUserDisable

### Changed
- Multiple updates to Sync-Exchange-Online-Group-To-Products.ps1

### [2022-07-01]

### Fixed
- Corrected function invoke-hidrestmethod
- Corrected invoke-hidrestmethod to get paged data

### [2022-06-23]

### Added
- Support to add Distribution Group owner(s) to HelloID Resource Owner Group

### [2022-06-22]

### Added
- Initial commit with base functionality
- Sync-Exchange-Online-Group-To-Products.ps1 script
