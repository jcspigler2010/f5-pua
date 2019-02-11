# Changelog
## [1.0.21] 20190211
### Fixes
- Ephemeral_Auth: LDAP escape characters causing invalid logins [#11](../../issues/21)
- Ephemeral_Auth: LDAP DNs over 128 characters causing exception messages in /var/log/ltm [#12](../../issues/22)
  - tested to 463 characters

## [1.0.20] 20181109
### Changed
- WebSSH2 v0.2.6
  - Reauth function, not exactly relevant to PUA use-case
  - `options.challengeButton` enabled
    - previously this configuration option did nothing, this now enables the Credentials button site-wide regardless of the `allowreplay` header value
  - Updated debug module to v4
- Ephemeral Auth v0.2.16
  - GenCred Feature see issue [#19](../../issues/19) for more details
  - **BREAKING** Removed ephemeral rotate logic from `ACCESS_ACL_ALLOWED` in `APM_ephemeral_auth.tcl`. Should be replaced with a _per request policy_ (PRP).

## [1.0.19] 20180912
### Fixed
- build_pua.sh contained an incorrect URL for WebSSH which would prevent installation from succeeding fixes #17

## [1.0.18] 20180911
### Changed
- Updated WebSSH2 to v0.2.5
### Fixed
- Properly incremented version
- When radiusoption was "n", radiusoption installed anyway, fixed.

## [1.0.17] 20180910
### Changed
### Fixed
- When radiusoption was "n", radiusoption installed anyway, fixed.

## [1.0.16] 20180718
### Changed
- WebSSH2 updated to v0.2.4 (4f506ad)
  - Changed WebSSH2 virtual, routing, and IP parameters (removed need for tmm route)
  - changed webssh2 translate-address enabled translate-port enabled
  - removed net 
  - removed `startup` scripts
  - WebSSH2 Proxy no longer requires it's own IP address
  - default answer for RADIUS Test option is now yes, it still asks "Are you sure" however defaults to yes as well.
- incremented ephemeral_auth version to reflect proper version (4f506ad)
- all virtual servers now utilize the `f5-tcp-lan` profile by default (consistent with `pua_webtop` vs). (4f506ad)

## [1.0.15.2] 20180509
### Changed
- Disable requirement for LTM provisioning
## [1.0.15.1] 20180509
### Changed
- Set pua_webtop-clientssl handshake timeout to 120. Prevents handshake timeouts when CAC/PIV/SmartCard is used and user takes too long to enter their PIN.
## [1.0.15] 20180404
### Changed
- Attempt to flush buffer before first key read... Minor.
## [1.0.14] 20180319
### Changed
- ephemeral_auth package updated to 0.2.13
### Fixed
- Typo in build_pua*.sh #2
## [1.0.13] 20180228
### Changed
- ephemeral_auth package updated to 0.2.10
# Changelog
## [1.0.12] 20180227
### Added
- Option to disable test account and enhanced logging with disabletest=y in `pua_config.sh`
# Changelog
## [1.0.11] 20180227
### Added
- Check for and trim leading/trailing whitespace/tab in IP address input
## [1.0.10] 20180223
### Changed
- Formatting and typos thanks to the eagle eye of Mr. Brad Otlin!
- Corrected script version variable and moved it to the top
## [1.0.9] 20180222
### Added
- Apply APM policy after creation
- pua_webtop-clientssl profile
- Sample CA option `sampleca`
- Installation of sample APM policy
### Changed
- Updated plugin names
- variables to lower case (costmetic/minor)
## [1.0.8] 20180221
### Added
- Config file option `pua_config.sh`
- Fully automated and Semi-automatic config
- This Changelog
### Changed
- Documentation updates
## [1.0.7] 20180220
### Changed
- Corrected typo for RADIUS configuration and IP configuration (superficial)
### Added
- TMOS version check
## [1.0.6] 20180220
### Added
- Introduction text
## [1.0.5] 20180220
### Added
- Self-extracting "offline" mode. Download build_pua_offline.sh for offline use
## [1.0.4] 20180220
### Changed
- Fixed typo
## [1.0.3] 20180220
### Changed
- Cleaned up error handling
## [1.0.2] 20180220
### Changed
- Cleaned up error reporting
## [1.0.1] 20180219
### Changed
- Disabled SNAT automap for webtop virtual server
## [1.0.0] 20180219
- Initial Release
