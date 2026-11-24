# zsetup-scripts Distribution

This context defines the language for publishing cross-platform application installers through one directly copyable applications tree.

## Language

**Application**:
A named installable product registered once in the applications tree.
_Avoid_: Script, package

**Standard Entry**:
The stable user-facing launcher for one runtime family; POSIX uses `install.sh` and Windows uses `install.ps1`.
_Avoid_: Alias, installer payload, short link

**Version Installer**:
The immutable implementation for one application version and runtime family.
_Avoid_: Standard entry, latest script

**Runtime Family**:
An execution environment shared by platforms; the supported families are POSIX and Windows PowerShell.
_Avoid_: Operating-system filename

**Compatibility Alias**:
A second published name for a standard entry. Layout v2 forbids compatibility aliases.
_Avoid_: Standard entry

**Website Route**:
A domain-specific public URL such as `run.ddnsto.com/i` that resolves to website runtime content without becoming an application entry name.
_Avoid_: Application entry, compatibility alias

**Product Artifact**:
A business-owned binary or archive consumed by a version installer and released outside the applications tree.
_Avoid_: Version installer

**Applications Release**:
An independently addressable snapshot of the complete applications tree used for verification, activation and rollback.
_Avoid_: Working tree, ad-hoc upload
