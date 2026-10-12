GOVERNMENT CONTENT PACK (STATE AND LOCAL) - COPILOT COE KIT 3.6
=================================================================

What this is
  An organization folder for the Copilot CoE kit, pre-filled with government wording. It uses the
  same kit and the same scripts as the higher-education build. Only the content differs.

  Works with: commercial and GCC-Moderate Microsoft 365 tenants (both use sharepoint.com and
  graph.microsoft.com). Not for GCC High or DoD.
  Requires: Copilot CoE kit 3.6 or later. It ships inside the kit at ContentPacks\Government-StateLocal.
  (3.5 kits ignore the prompt files; earlier kits also reject the government settings.)

How to use it
  1. Copy this whole folder OUT of the kit to a working location, for example C:\CoE-Orgs\<Agency>.
  2. Open Deployment-Settings.json and replace every <placeholder>: tenant, owner, OrgName,
     SupportEmail, ChampionDepartments and the Links (service desk, technology request,
     data/safety incident, AI guidelines). Set TimeZone to the agency's Windows time zone ID,
     for example "Central Standard Time".
  3. Put the agency's own files in Assets\ (see each README), and replace any Content\ file
     you want to change. Each file in Content\ replaces the kit file at the same path.
  4. From the kit folder run, in order:
       .\01_Register-CoEProvisioningApp.ps1 -OrgPath <folder>     (once per tenant)
       .\02_Install-CopilotCoE.ps1 -OrgPath <folder> -SeedDemoContent -AcceptOrgAssets
       .\Test-CoEInstall.ps1 -OrgPath <folder> -SiteUrl <site URL printed by the install>
     Do not use -ResumeExisting to recover a failed install; remove the site with
     04_Remove-CopilotCoE.ps1 -Purge and install again.

What the pack changes (compared with the kit's higher-education content)
  Settings   OrgNoun "agency"; GuidesIntro for staff, supervisors and IT; story audiences
             Staff / Supervisors / IT; the Teams Scenario Library tab opens the government scenarios.
  Guides     Start in 10 minutes, Is this OK, Who gets what, Data readiness, Agents, Stay current,
             Prompt library (rewritten for government tasks: plain-language notices, replies to
             residents, briefings, procedures), Measuring impact, Concerns and myths, Champions toolkit.
             "Students and AI" and "Teaching and learning" are left out (empty files).
  Pages      Training, Success Stories, Governance and Responsible AI, Feedback and Roadmap, FAQs,
             Give feedback. Sample stories are marked SAMPLE and start as pending.
  Learning   Learning paths for Staff, Supervisors, Champions, IT and Agent makers.
  Prompts    Copilot Prompt Library list with 230 general government prompts
             (Content\OrgPrompts\gcc_prompt_library_import_1..3_of_3.csv, admin center import format).
             The three empty highered_prompt_library_*.csv files keep the higher-ed prompts out.
             Add the agency's own prompt CSVs to Content\OrgPrompts (see the README there).
  Calendar   Six DRAFT - DEMONSTRATION sessions (October to December 2026).
  Governance All twelve Leadership and Program Governance drafts and both Start here notes,
             rewritten for government:
             program and legal authority, Low/Moderate/High data, public records and retention,
             labor-management, no automated decisions about people. The separate overarching policy
             draft is left out (empty Content\Higher-Ed-AI-Governance-Framework-DRAFT.md); the
             acceptable-use policy in 03-Policy-and-Risk-Decisions covers it.
  Checklist  CoE-Revision-Content.json: government champion examples and owner-checklist wording.
             Keep its "version" value equal to the kit's (3.6).

Before showing it to an agency
  - Every governance document is an ILLUSTRATIVE DRAFT, not policy. Say so.
  - The data levels (Low/Moderate/High) are generic. Replace them with the agency's own
    classification standard, especially in Guides\00b-Is-This-OK.md and
    Sections\03-Governance-and-Responsible-AI.md.
  - Confirm which Copilot features the tenant actually has. Some agent and Researcher features
    reach GCC later than commercial; check the Microsoft 365 roadmap for GCC before promising them.

  - Organization prompts in the Microsoft 365 admin center: Microsoft's announcement (MC1396361) lists
    Worldwide availability; confirm GCC availability before relying on it. The CoE list works in GCC either way.
