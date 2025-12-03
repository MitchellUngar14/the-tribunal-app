# Web UI Installation Scripts

This folder contains automation scripts for installing, uninstalling, and managing the Ratabase Web UI.

---

## Scripts

- `RunDeployment.ps1` - Installs and configures the Ratabase Web UI client and API for all environments.
- `DeploymentHelpers.psm1` - PowerShell module containing helper functions for deployment scripts.
- `GlobalVariables.psd1` - PowerShell data file for global variables used by deployment scripts.
- `Run-SqlMigrations.ps1` - Runs SQL migration scripts against the databases.
- `StartIISServices.ps1` - Starts all IIS application pools and sites for all environments.
- `StopIISServices.ps1` - Stops all IIS application pools and sites for all environments.
- `UninstallAllEnvironments.ps1` - Discovers and calls the uninstaller for all environments.
- `UninstallEnvironments.ps1` - Uninstalls products by their exact installation location.
- `ValidateEnvironments.ps1` - Validates the configuration and state of Ratabase Web UI environments.
- `Environments/TestEnvironment.psd1` - Example PowerShell data file for a 'Test' environment configuration.

---
