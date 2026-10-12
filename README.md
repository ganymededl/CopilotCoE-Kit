# Microsoft 365 Copilot CoE — Implementation Kit

A config-driven Teams + SharePoint **Center of Excellence (CoE)** kit for organizations rolling out Microsoft 365 Copilot. One kit, any organization: everything organization-specific (tenant, names, support links, policies, decks) lives in an **organization folder** passed to every script with `-OrgPath`, never edited in the kit itself.

> **Not an official Microsoft product.** This is independently maintained sample/starter tooling. All seeded content (guides, FAQs, governance samples, prompt libraries) is starter material for your organization's own review — none of it is adopted policy, and no customer or tenant is implied, named, or endorsed by shipping this kit.

## What it builds

- A **Private** Microsoft Team + SharePoint communication site, with external sharing **disabled by default**
- Role-based learning paths, a prompt library, governance/RACI starter pages, a success-stories catalog with native SharePoint content approval, and an agent showcase
- Everything is re-runnable and reversible: `03_Update-CoEContent.ps1` republishes edited content, `04_Remove-CopilotCoE.ps1` tears it down (soft-delete by default, `-Purge` for permanent)

## Quick start

1. Read **[`CopilotCoE-Kit/START-HERE.txt`](CopilotCoE-Kit/START-HERE.txt)** and **`CopilotCoE-Kit/01_Admin-Quickstart.html`** first.
2. This repo excludes one ~175 MB vendor template package (`SourceOriginal/CopilotCoESite/CopilotCoESite.pnp`) because it exceeds GitHub's 100 MB per-file push limit. Download it from this repo's **[Releases](../../releases)** page and place it at:
   ```
   SourceOriginal/CopilotCoESite/CopilotCoESite.pnp
   ```
3. Copy `CopilotCoE-Kit/Org-Template` (or `CopilotCoE-Kit/ContentPacks/Government-StateLocal` for state/local government) to an organization folder **outside** this repo, e.g. `C:\CoE-Orgs\Contoso`, and fill in its `Deployment-Settings.json`.
4. Run the numbered scripts in order from inside `CopilotCoE-Kit/`:
   ```powershell
   Install-Module PnP.PowerShell -RequiredVersion 3.2.0 -Scope CurrentUser
   .\01_Register-CoEProvisioningApp.ps1 -OrgPath C:\CoE-Orgs\Contoso
   .\02_Install-CopilotCoE.ps1 -OrgPath C:\CoE-Orgs\Contoso -SeedDemoContent
   .\Test-CoEInstall.ps1 -OrgPath C:\CoE-Orgs\Contoso -SiteUrl https://contoso.sharepoint.com/sites/CopilotCoE
   ```

## Security model

- **Interactive, delegated-only authentication** via a tenant-owned, single-tenant Entra app (`01_Register-CoEProvisioningApp.ps1`). No certificates or stored secrets.
- Customer installs default to **external sharing OFF**, **Private** Team visibility, and owner-only sharing; lab/preview access is an explicit, separate opt-in — never the default.
- Every install/update run prints a live security-posture report (Team visibility, site sharing capability, governance-channel membership against an allowlist) and writes a local, never-committed audit trail.
- The provisioning app uses the high-privilege delegated `AllSites.FullControl` SharePoint scope. Use a dedicated admin identity, review your tenant's admin-consent policy, and remove the app registration when no longer needed.
- This repo's `.gitignore` excludes anything that is organization-specific or regenerated per run: `RevisionAudit/` transcripts, the built `CopilotCoESite.pnp` / `TeamTemplate-CoE.xml` / `SiteAssetManifest.json` (rebuilt fresh from source on every install), and any local `Orgs/` or organization folders. **Never commit an organization folder or its `Deployment-Settings.json` once filled in** — it contains your tenant hostname, support routes, and admin UPNs.

## Repository layout

```
CopilotCoE-Kit/        The kit: numbered scripts, Org-Template, ContentPacks, SeedContent, Internal helpers
SourceOriginal/         Vendor-sourced SharePoint site template (CopilotCoESite.pnp via Release asset, see above)
```

## License

[MIT](LICENSE)

---
Master kit prepared by David Shih Chun Liu.
