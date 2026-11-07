# Microsoft 365 Copilot CoE — Implementation Kit

A config-driven Teams + SharePoint **Center of Excellence (CoE)** kit for organizations rolling out Microsoft 365 Copilot. One kit, any organization: everything organization-specific (tenant, names, support links, policies, decks) lives in an **organization folder** passed to every script with `-OrgPath`, never edited in the kit itself.

Release: **v3.8.24**. Customers install the named [`Copilot-CoE-Implementation-Kit.zip`](https://github.com/ganymededl/CopilotCoE-Kit/releases/download/v3.8.24/Copilot-CoE-Implementation-Kit.zip) release asset and verify SHA256 `EFD59EDD830FDBE4FC7C83ECCA1163AAE98818234C645E71B1B7595D7B91BA9D` against its [`.sha256` receipt](https://github.com/ganymededl/CopilotCoE-Kit/releases/download/v3.8.24/Copilot-CoE-Implementation-Kit.zip.sha256). GitHub's automatic **Source code (zip)**, **Source code (tar.gz)** and repository **Download ZIP** are source snapshots, not the prebuilt implementation ZIP; cloning GitHub and renaming an older ZIP does not produce it.

> **Pending release change:** The provisioning app now requests delegated Microsoft Graph permission `TeamsAppInstallation.ReadWriteForTeam`. This lets the installer add a tab's approved Teams app to a fresh Team scope before retrying tab creation. Any tenant previously registered under the old five-permission app must add this delegated permission and grant admin consent again before using the updated kit.
>
> If Teams still refuses a tab after the approved app installation, or reports success without exposing the tab, the run can complete with explicit `ManualStepsRequired` entries in `CoE-Revision-Report.json`. These are not successful tab creations. For shared-channel SharePoint pages, the current Teams **Page > Existing page** picker may accept only Loop pages; do not substitute a Loop or Website tab. Keep the page as the channel site's home page and retain the report entry as a compatibility exception until Teams exposes a supported SharePoint page-tab option.
>
> The checker now honors its documented optional-mode behavior: omitting `-ContentMode` skips mode-specific notice checks. Release 3.8.24 operators should still pass the same explicit mode used for install; an omitted mode in that release can produce false missing-notice failures.

> **Not an official Microsoft product.** This is independently maintained sample/starter tooling. All seeded content (guides, FAQs, governance samples, prompt libraries) is starter material for your organization's own review — none of it is adopted policy, and no customer or tenant is implied, named, or endorsed by shipping this kit.

## What it builds

- A **Private** Microsoft Team + SharePoint communication site, with external sharing **disabled by default**
- Role-based learning paths, a prompt library, governance/RACI starter pages, a success-stories catalog with native SharePoint content approval, and an agent showcase
- Everything is re-runnable and reversible: `03_Update-CoEContent.ps1` republishes edited content, `04_Remove-CopilotCoE.ps1` tears it down (soft-delete by default, `-Purge` for permanent)

## Quick start

Run these steps **one block at a time in PowerShell 7.4 or later**. The first tenant operation is script 01; download, extraction, configuration, and content preflight are local.

1. **Download the installable release assets.** Download the named [`Copilot-CoE-Implementation-Kit.zip`](https://github.com/ganymededl/CopilotCoE-Kit/releases/download/v3.8.24/Copilot-CoE-Implementation-Kit.zip) and its [`.sha256` receipt](https://github.com/ganymededl/CopilotCoE-Kit/releases/download/v3.8.24/Copilot-CoE-Implementation-Kit.zip.sha256). Do not use GitHub's **Code > Download ZIP**, **Source code (zip)**, or **Source code (tar.gz)**; those are source snapshots, not the implementation package.

2. **Verify and unblock the ZIP before extracting it.** Windows marks internet downloads as untrusted. If the ZIP is extracted while still blocked, PowerShell can reject every `.ps1` file as "not digitally signed."

   ```powershell
   $zip = 'C:\CoE-Releases\Copilot-CoE-Implementation-Kit.zip'
   $receipt = 'C:\CoE-Releases\Copilot-CoE-Implementation-Kit.zip.sha256'
   $expectedHash = 'EFD59EDD830FDBE4FC7C83ECCA1163AAE98818234C645E71B1B7595D7B91BA9D'

   $zipHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
   $receiptHash = ((Get-Content -LiteralPath $receipt -Raw).Trim() -split '\s+')[0]
   if ($zipHash -ne $expectedHash -or $receiptHash -ne $expectedHash) {
       throw 'The implementation ZIP or its receipt does not match release 3.8.24.'
   }
   Unblock-File -LiteralPath $zip
   ```

   GUI equivalent: right-click the ZIP, select **Properties**, select **Unblock** if shown, then select **OK**. Do this **before** **Extract All**. If the ZIP was already extracted while blocked, either delete that extraction and start again from the unblocked ZIP (recommended), or unblock the existing files:

   ```powershell
   Get-ChildItem -LiteralPath 'C:\CoE-Install\Contoso' -Recurse -File | Unblock-File
   ```

3. **Extract the kit into a fresh installation folder.** Keep the kit and customer configuration in different folders.

   ```powershell
   $installRoot = 'C:\CoE-Install\Contoso-v3.8.24'
   $kitRoot = Join-Path $installRoot '03_Build\CopilotCoE-Kit'
   $orgPath = 'C:\CoE-Orgs\Contoso'

   if (Test-Path -LiteralPath $installRoot) { throw "Use a new install folder: $installRoot" }
   Expand-Archive -LiteralPath $zip -DestinationPath $installRoot
   Set-Location $kitRoot
   ```

4. **Create a separate organization folder.** `-OrgPath` must point to this copied profile, not to the extracted package root or the `Internal` folder.

   ```powershell
   if (Test-Path -LiteralPath $orgPath) { throw "Review the existing organization folder first: $orgPath" }
   Copy-Item -LiteralPath '.\Org-Template' -Destination $orgPath -Recurse
   # State/local government instead:
   # Copy-Item -LiteralPath '.\ContentPacks\Government-StateLocal' -Destination $orgPath -Recurse
   ```

   Edit `$orgPath\Deployment-Settings.json`, not a settings file under `$kitRoot`. Complete at least `Tenant`, `AdminFQDN`, `SiteFQDN`, `SharedChannelOwnerUPN`, `OrgName`, `MailNickname`, and `SupportEmail`. Leave `PnPClientID` blank if script 01 will create the tenant app. Do not copy another deployment's `CoE-Revision-Report.json`, removal manifest, advisory decisions, or `RevisionAudit`.

5. **Run the local content preflight correctly.** The leading dot and following space in `. .\Internal\ContentPreflight.ps1` are required: they load the function into the current PowerShell session. Running only `.\Internal\ContentPreflight.ps1` does not leave `Assert-CoEStructuredOrganizationContent` available afterward.

   ```powershell
   Set-Location $kitRoot
   . .\Internal\ContentPreflight.ps1
   Get-Command Assert-CoEStructuredOrganizationContent -ErrorAction Stop
   Assert-CoEStructuredOrganizationContent -OrgPath $orgPath
   Write-Host 'Offline content preflight completed.'
   ```

   The assertion can finish silently when the organization profile has no `Content\Training-Calendar.csv` override. The `Get-Command` line confirms that dot-sourcing worked, and the final message makes successful completion explicit. This step does not connect to Microsoft 365.

6. **Install the required module, then register or reuse the tenant app.** Paste only the commands inside the code block; do not copy PowerShell prompt text such as `PS C:\...>` or continuation prompts such as `>>`. If `PnPClientID` already identifies this tenant's approved kit app, verify all required delegated permissions and **Allow public client flows = Yes**, then skip script 01. Script 01 creates a new app; rerunning it creates a duplicate, overwrites this profile's `PnPClientID`, and leaves the prior app in Entra.

   ```powershell
   # Re-enter the actual paths if you opened a new PowerShell window.
   $kitRoot = 'C:\CoE-Install\Contoso-v3.8.24\03_Build\CopilotCoE-Kit'
   $orgPath = 'C:\CoE-Orgs\Contoso'
   Set-Location -LiteralPath $kitRoot

   if (-not (Get-Module PnP.PowerShell -ListAvailable |
           Where-Object Version -eq ([version]'3.2.0'))) {
       if (-not (Get-PSResourceRepository -Name PSGallery -ErrorAction SilentlyContinue)) {
           Register-PSResourceRepository -PSGallery
       }
       Install-PSResource PnP.PowerShell -Version 3.2.0 -Scope CurrentUser `
           -Repository PSGallery -TrustRepository
   }
   Import-Module PnP.PowerShell -RequiredVersion 3.2.0 -ErrorAction Stop
   Get-Module PnP.PowerShell -ListAvailable |
       Where-Object Version -eq ([version]'3.2.0') |
       Select-Object Name, Version, Path
   .\01_Register-CoEProvisioningApp.ps1 -OrgPath $orgPath -Interactive
   ```

   Use `Install-PSResource`, included with supported PowerShell 7 releases, rather than the legacy
   `Install-Module` command. The repository check handles machines where PowerShell Gallery is not yet registered;
   the import then fails locally and clearly if the exact required module version is unavailable. Do not run `pwsh`
   between these commands: that opens a new session and clears `$kitRoot` and `$orgPath`. If you open a new window,
   re-enter the path assignments at the top of the block.

   Script 01 is the first tenant operation. Confirm all required delegated permissions show **Granted** and **Authentication > Settings > Allow public client flows** is **Yes**. An organization profile in the same tenant can reuse an already approved kit app by setting `PnPClientID`; never reuse that ID across tenants.

7. **Run the installation by itself.** Use `Customer` for an approved customer deployment. Use `Demo` only for a clearly labeled synthetic demonstration, and keep the same mode for install, update, and tests. Do not append report-reading or checker commands to this block.

   ```powershell
   $ErrorActionPreference = 'Stop'
   $kitRoot = 'C:\CoE-Install\Contoso-v3.8.24\03_Build\CopilotCoE-Kit'
   $orgPath = 'C:\CoE-Orgs\Contoso'
   $contentMode = 'Customer' # Use 'Demo' only for a labeled internal demonstration.
   Set-Location -LiteralPath $kitRoot

   $settings = Get-Content (Join-Path $orgPath 'Deployment-Settings.json') -Raw | ConvertFrom-Json
   if ([string]::IsNullOrWhiteSpace($settings.PnPClientID)) {
       throw 'Run script 01 and confirm admin consent before installation.'
   }

   try {
       & .\02_Install-CopilotCoE.ps1 `
           -OrgPath $orgPath `
           -ContentMode $contentMode `
           -SeedDemoContent
   } catch {
       Write-Host 'Installation stopped. Do not run the checker or start another clean install.' -ForegroundColor Red
       throw
   }
   ```

   Wait for script 02 to print its completion message. Do not add `-ResumeExisting` to a fresh installation. If script 02 stops after creating resources, inspect its saved transcript and verify the existing Team and site before deciding whether to resume.

8. **Only after installation completes, run the checker as a separate block.** This block restores every variable it needs and reads the actual site URL from the completed deployment report.

   ```powershell
   $kitRoot = 'C:\CoE-Install\Contoso-v3.8.24\03_Build\CopilotCoE-Kit'
   $orgPath = 'C:\CoE-Orgs\Contoso'
   $contentMode = 'Customer' # Must match the installation mode.
   Set-Location -LiteralPath $kitRoot

   $reportPath = Join-Path $orgPath 'CoE-Revision-Report.json'
   if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
       throw 'No completed deployment report exists. Stop and investigate the installation.'
   }
   $siteUrl = (Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json).Site
   if ([string]::IsNullOrWhiteSpace($siteUrl)) {
       throw 'The completed deployment report has no site URL.'
   }

   .\Test-CoEInstall.ps1 `
       -OrgPath $orgPath `
       -SiteUrl $siteUrl `
       -ContentMode $contentMode
   if ($LASTEXITCODE -ne 0) { throw 'Checker failed; stop and investigate.' }
   ```

   `ALL CHECKS PASSED` with a `WARN` still requires the named manual review. In Teams, confirm exactly one prepared welcome post in General, Ask Us Anything, and Share Your Prompt.

9. **Publish reviewed changes, then run step 8 again.** Do not append the checker to the update command; wait for script 03 to complete successfully first.

   ```powershell
   $ErrorActionPreference = 'Stop'
   $kitRoot = 'C:\CoE-Install\Contoso-v3.8.24\03_Build\CopilotCoE-Kit'
   $orgPath = 'C:\CoE-Orgs\Contoso'
   $contentMode = 'Customer'
   Set-Location -LiteralPath $kitRoot

   .\03_Update-CoEContent.ps1 `
       -OrgPath $orgPath `
       -Scope All `
       -AuthenticationMode Interactive `
       -ContentMode $contentMode
   ```

For source development, read [`CopilotCoE-Kit/START-HERE.txt`](CopilotCoE-Kit/START-HERE.txt) and `CopilotCoE-Kit/01_Admin-Quickstart.html`. The source repository excludes `SourceOriginal/CopilotCoESite/CopilotCoESite.pnp` because it exceeds GitHub's 100 MB per-file limit. Use the reviewed [v3.8.12 template asset](https://github.com/ganymededl/CopilotCoE-Kit/releases/download/v3.8.12/CopilotCoESite.pnp) and verify SHA256 `2CC80587026E27B47992330122B75DEA4808E01D3DA2CB46EEF3EA404FF429CB`.

## v3.8.24 changes

- **Fixed a live defect that silently emptied the Microsoft Mechanics hub page.** The page's body write went through `Write-ManagedPage`'s generic "remove every control, then re-add" path, which is safe for the kit's own pages but deletes the vendor's real video embeds on this one vendor-captured page. A dedicated `Write-CoEMechanicsNotice` function now replaces only its own breadcrumb/notice/body control and never touches the video embeds; `Test-CoEInstall.ps1` independently asserts the page's real body text and links are present, not just a breadcrumb.
- **Added a per-channel welcome-post journal** (`CoE-Welcome-Post-State.json`) tracking Pending/Posting/Posted state for the three standard-channel welcome posts. A clean install records sends as it goes; `-ResumeExisting`/`-PublishWelcomeToChannels` now automatically (re)posts only channels verifiably still Pending, without `ChannelMessage.Read.All`. Legacy organization folders with no journal file fall back to the prior manual-check warning instead of guessing.
- **Clarified Learning Paths external training links.** Rows now carry a distinct `lmsUrl` ("External training") separate from Practice; the kit's own seed content points 11 of 18 rows to a specific, verified Microsoft Learn module per step instead of a repeated generic link. `Links.LearningSystem` is now documented as a fallback that only fills rows still missing a link, never a blanket override of a per-row destination.
- **Documented the access model.** `CopilotCoE-Kit/Org-Template/README.txt` now explains Team membership (the kit's actual access control) versus SharePoint Visitors/reviewer groups (narrow, kit-managed exceptions), and the `GovernanceAdditionalAllowedMembers` workflow enforced by the shared-channel governance gate.
- Local content preflight now accepts `Agents: []` and fully blank optional agent objects before any tenant write, instead of surfacing a late tenant-side error.
- `Write-ManagedPage` correctly repairs a captured page whose canvas has only a full-width section, writing the replacement text into a valid regular section instead of silently no-op'ing.
- The Ask Us Anything channel-folder lookup now goes through the kit's existing retry/destination-validation helper instead of a raw, unretried Graph call.
- Fixed the release packager itself: it was omitting `TeamTemplate.xml` and the three Share Your Prompt files from `SourceOriginal` in the built ZIP. Fixed with a regression test, and the `.gitignore` now documents why `Package-CoE-Kit.ps1` and `ApprovedQuickstartImages.json` are maintainer-only and never shipped or committed.
- Added admin-quickstart/START-HERE troubleshooting for the most common first error when a step is run from a fresh window or Windows PowerShell 5.1 instead of PowerShell 7.4+ (`...ScriptRequiresUnmatchedPSVersion`).
- Full offline gate: **717 passed, 0 failed, 0 skipped across 18 Pester suites.** Separately validated live in a tenant: post-hotfix checker passed 281 automated checks with 0 failures and 2 expected manual WARNs.

## v3.8.23 changes

- The packaged administrator quickstart now makes Windows ZIP unblocking a required pre-extraction step and gives recovery instructions for files extracted while blocked.
- The offline content preflight explains the required dot-space syntax, verifies that the assertion function loaded, and prints an explicit completion message when no structured override produces output.
- Setup is divided into separate verification, extraction, organization-profile, module-installation, app-registration, installation, and checker steps.
- All guides warn that script 01 creates a new Entra app on every run. Reuse an existing tenant app by setting `PnPClientID` and skip script 01; rerunning it creates a duplicate and overwrites the profile's client ID without removing the old app.
- The packaged ZIP was rebuilt from the frozen v3.8.22 implementation asset with the reviewed nested `.pnp` template unchanged. The extracted-package offline gate passed 686 tests with 0 failures and 9 expected authoring-only skips.

## v3.8.22 changes

- Scripts 01–04, `Test-CoEInstall.ps1` and `Test-CoELiveRegression.ps1` check that the provisioning app has **Authentication > Settings > Allow public client flows** set to Yes before sign-in, and stop with the exact Entra path when Entra reports it is off (`AADSTS7000218`) or that the app is not in the tenant (`AADSTS700016`). Any other probe result (network or proxy failure, a Conditional Access or authentication-flow policy) is a warning; sign-in still happens before anything is created. Script 01 does not change the setting itself; it checks the app it registered.
- `CoE-Revision-Report.json` records `KitRelease` from the packaged `VERSION.txt`.
- Updates (`03_Update-CoEContent.ps1`) verify the target before any tenant write: the alias must resolve to the supplied site, and the Team must match the `TeamId` saved in `CoE-Revision-Report.json`. A reused alias or site stops with nothing changed. Reports from older kits without `TeamId` continue with a warning and record it on completion.
- `Test-CoELiveRegression.ps1` writes only to `https://<SiteFQDN>/<managed path>/CoEScratch*` (never the configured alias) unless `-AllowAnySite` is passed. R5 now compares a full snapshot of catalog rows, versions, approval state, views, fields, permissions and reviewer membership across a synchronizer rerun; it is not a full 02/03 rerun test.
- The Share Your Prompt `ScenarioUseCaseTemplate.pptx` is replaced with an unencrypted copy.
- The Government pack's `CoE-Revision-Content.json` version matches the base kit (3.8.5).
- Government tool pages tell readers to confirm current GCC availability for Researcher, Analyst and SharePoint agents.
- `02_Install-CopilotCoE.ps1` is ASCII-only (the Ask Us Anything channel emoji is built from its code point).
- Customer-mode Step 08 publishes with a plain `-Scope All` update; `-RepairCapturedPages` is for internal test sites or reviewed repair only.
- v3.8.22 has not been re-run end to end in a tenant. Run the Windows PowerShell 5.1 offline gate (`Tests\Invoke-CoETests.ps1`) and your own acceptance before relying on it.

## v3.8.21 acceptance and reliability

- `02_Install-CopilotCoE.ps1` and `03_Update-CoEContent.ps1` validate structured organization overrides before tenant connection. An obsolete fixed-date `Training-Calendar.csv`, malformed offsets/times, or duplicate session title stops locally with corrective guidance.
- Updates resolve the existing SharePoint site from the deployment report or an explicit `-SiteUrl`, supporting tenants whose managed path is not `/sites/`.
- `03_Update-CoEContent.ps1` and `04_Remove-CopilotCoE.ps1` support interactive sign-in for tenants that block device-code flow.
- The installer checks Microsoft Entra group naming policy and owner/operator differences before resource creation when permissions allow. Its least-privilege delegated app intentionally omits `Directory.Read.All`, so the optional `groupSettings` read can return `Insufficient privileges` even for a Global Administrator. That warning is non-blocking but requires a manual naming-policy check; do not add broad directory-read consent solely to suppress it.
- Before installation, allow the built-in Teams Website, PDF, PowerPoint and SharePoint page/list tab providers for the installer and intended CoE audience. A Teams app-policy denial is a recoverable partial install: correct the tenant policy and use `-ResumeExisting`; do not start clean or purge.
- Newly provisioned shared-channel folders receive bounded retries for transient 404/NotFound, throttling, timeout, and service-availability errors. Access failures and other hard errors still stop immediately.
- Site Page content types/libraries use stable identifiers rather than English display names; time-zone mismatches warn and leave the existing setting unchanged rather than guessing from UTC offset.
- The checker resolves `SampleNotice` consistently, validates empty support-route notices, and reports a passing detail instead of displaying failure text on PASS.
- Run `Test-CoEInstall.ps1` separately after every install/update. After an interruption, retain logs, verify the exact target and fix the cause before choosing resume. A fresh release acceptance must not use resume.
- For a reviewed rebuild, preview `04_Remove-CopilotCoE.ps1 -Purge -WhatIf`, then complete the separately confirmed purge. Do not rebuild until `AliasReusable` is true. The numbered scripts require no launcher reset.
- The accepted v3.8.21 E2E used a synthetic Government-content demo tenant; it is not customer production or GCC acceptance. GCC High and DoD remain unsupported. Replace all lab support/incident destinations before production.

## Security model

- **Interactive, delegated-only authentication** via a tenant-owned, single-tenant Entra app (`01_Register-CoEProvisioningApp.ps1`). No certificates or stored secrets.
- Customer installs default to **external sharing OFF**, **Private** Team visibility, and owner-only sharing; lab/preview access is an explicit, separate opt-in — never the default.
- Every install/update run prints a live security-posture report (Team visibility, site sharing capability, governance-channel membership against an allowlist) and writes a local, never-committed audit trail.
- The provisioning app uses the high-privilege delegated `AllSites.FullControl` SharePoint scope. Use a dedicated admin identity, review your tenant's admin-consent policy, and remove the app registration when no longer needed.
- Teams channel posting currently works with delegated `Group.ReadWrite.All`; Microsoft Graph supports it for message sending only for backward compatibility. `ChannelMessage.Send` is the recommended least-privileged posting permission for a future reviewed consent change. Do not silently add `ChannelMessage.Read.All` across the tenant just to remove a test warning.
- This repo's `.gitignore` excludes named runtime artifacts: `RevisionAudit/` transcripts, built templates, advisory decisions, deployment/removal/purge records, launcher state, backups and local `Orgs/`. **Never commit an organization folder or its `Deployment-Settings.json` once filled in** — it contains your tenant hostname, support routes, and admin UPNs. Ignore rules do not protect a tracked neutral settings file after someone fills it in; review the exact staged diff before publishing.

## Repository layout

```
CopilotCoE-Kit/        The kit: numbered scripts, Org-Template, ContentPacks, SeedContent, Internal helpers
SourceOriginal/         Vendor-sourced SharePoint site template (CopilotCoESite.pnp via Release asset, see above)
```

## License

[MIT](LICENSE)

---
Master kit prepared by David Shih Chun Liu.
