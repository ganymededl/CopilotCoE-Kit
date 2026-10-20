ORGANIZATION FOLDER - ONE PER ORGANIZATION (NOT INSIDE THE KIT)

Copy this whole folder once per organization, for example C:\CoE-Orgs\Contoso,
fill it in, and pass it to every script:
    .\01_Register-CoEProvisioningApp.ps1 -OrgPath C:\CoE-Orgs\Contoso
    .\02_Install-CopilotCoE.ps1     -OrgPath C:\CoE-Orgs\Contoso -SeedDemoContent
    .\03_Update-CoEContent.ps1         -OrgPath C:\CoE-Orgs\Contoso -Scope All
    .\04_Remove-CopilotCoE.ps1      -OrgPath C:\CoE-Orgs\Contoso -WhatIf
The kit never changes between organizations; everything specific lives here.
Full guide, with an example: Installation Runbook section 6 (Customize the CoE).

=====================================================================================
HOW TO CUSTOMIZE - THREE PLACES, ONE COMMAND
=====================================================================================
  1. Deployment-Settings.json  names, mailbox, links, agents, navigation order.
  2. Content\                  your version of any kit text file (copy, then edit).
  3. Assets\                   your own files to host (decks, PDFs, videos).
  Then publish:  .\03_Update-CoEContent.ps1 -OrgPath <this folder> -Scope <Guides|Governance|All>
  Changes made before the first install are picked up by 02_Install automatically.
  Never edit the kit's SeedContent folder: your changes would be lost when the kit is
  updated, and they would appear in every other organization built from the kit.

Deployment-Settings.json   REQUIRED. Tenant, names, support mailbox, and links.
  OrgName       Full organization name used in page text ("Contoso University").
                Existing OrgName values are kept even when the hub has a custom DisplayName.
                If OrgName is omitted/blank, DisplayName supplies the organization name instead.
  DisplayName   Team/hub title (blank = "<OrgName> Copilot CoE").
  OrgNoun       OPTIONAL grammar label ("university", "college"; blank/omitted = "organization").
                Do not use lab labels such as "Test tenant" in reader-facing text.
  ShortName     Short label (blank = initials of OrgName).
  SupportEmail  Mailbox behind every Service Catalog request link.
  SampleNotice  Line shown at the top of every page (blank = sample notice for the selected OrgName;
                "none" = no line, once the content is approved).
  Links         ServiceDesk, TechnologyRequest, AIGuidelines, AboutOrg page URLs (blank = text only).
                Optional PromptLibrary is the HTTPS link to your existing customer-approved prompt library.
                Optional LearningSystem is the HTTPS link to your LMS; no LMS integration or completion tracking is created.
                Optional DataSafetyIncident is an approved HTTPS incident-reporting route;
                blank = the Service Catalog/support mailbox route, not a tenant security setting.
  Home          On a fresh install, the kit replaces the captured five-tile layout with the
                approved 3.7 Home. Old HomeTiles settings are not supported; remove them
                before installation. Existing customized Home pages are preserved on updates
                unless -RepairCapturedPages is explicitly requested.
  GovernanceLinks / TrainingLinks   Lists of {label, url} shown on those pages.
  Agents        Insert-only seed proposals for the existing Agent Showcase list: name, description, audience,
                examplePrompt, owner, url. The url is the agent's Copilot Chat link
                (open the agent in Copilot Chat, Share > Copy link, e.g.
                https://m365.cloud.microsoft/chat/?titleId=T_...). The neutral placeholder with an empty url is skipped.
                New real links default to pending native approval, legacy status Submitted and featured=false.
                Backward compatibility: a seed explicitly configured as status Published is approved at
                insertion only with owner, sources, access, allowedData and reviewedOn (yyyy-MM-dd);
                no future review date. This is a reviewed-seed import option, not the live publication workflow.
                Optional metadata: product, connections, backupOwner, support, nextReview (yyyy-MM-dd).
                Existing rows matched by title or exact launch URL are preserved, including links and edits.
                Edit existing rows in SharePoint, not by changing configuration. Featured selects approved highlights.
                Legacy status Featured becomes Published + Featured. When the Featured field is first added,
                existing Published rows matching the old configured highlights are marked Featured.
  CatalogReviewerUPNs
                Optional array of existing in-tenant Member UPNs who review both catalogs.
                Empty = no additional reviewer grants; existing list permissions remain unchanged.
                Named reviewers receive CoE Catalog Reviewer: the localized Contribute permission level
                plus ApproveItems, with no ManageLists or permission-management rights. Plain Contribute
                cannot approve, which is why the approval permission is added. No guests are invited.
                Inheritance is copied only if a named reviewer needs a list-specific grant; other writers,
                readers, owners and administrators retain their existing grants. Former reviewer removal
                is an explicit administrator action, not an automatic downgrade on rerun.
                Both lists enable versioning, content approval and Approver draft visibility. Drafts remain
                visible to their authors and approvers; keep confidential evidence outside the catalogs.
                Unique item permissions stop the update before catalog changes; they are not reset.
                The CoE Catalog Reviewer level is site-collection scoped, not tenant-wide. It is listed in
                CoE-Revision-Report.json under AgentCatalog.ReviewerPermissionLevel. Removing the entire CoE
                site through 04_Remove removes its role definitions with it; soft deletion retains them for
                restoration, and permanent site purge removes them. Do not separately delete the level before
                soft deletion: that would alter a restored site's permissions. If keeping the site but removing
                only the catalogs manually, check all grants referencing this level before manually removing it.
  NavigationOrder     "TaskFirst" (default) builds a horizontal mega menu without changing the Teams site type;
                      "AToZ" opts into alphabetical order; "AsBuilt" leaves build order.
                      Applied by 02 and by 03 -Scope Guides/All.
  NavigationPinFirst  Links kept first (default [ "Home" ]). Site contents stays last.
  LearningEnvironment REQUIRED: "HigherEducation" (this template) or "Government".
                Missing or unrecognized values stop installation and content updates before sign-in.
                Controls Educators and Students tracks and government-specific tool links;
                all four common audience tracks remain visible.
  EnableDeveloperTrack  false by default; true adds Developers and developer tool pages.
  TimeZone      Windows time zone ID for the site's regional settings (default "Eastern Standard Time";
                list: Get-TimeZone -ListAvailable). Training-calendar times are read in this zone.
  ChampionDepartments  Your real units for the Department Champions directory, for example
                [ "Office of Information Technology", "Library" ]. Each starts as "Not assigned".
                Blank = the kit's generic sample rows. Rows already on the site are not changed.
  PnPClientID   Filled in by script 01. Organizations in the same tenant can share one app:
                copy the ID into each organization's file instead of running 01 again.
  TeamVisibility   Must remain "Private". The installer rejects Public Teams.
  CoESiteSharingCapability
                Default "Disabled": customer deployments are internal-only. Missing settings
                also default to Disabled. Keep all customer organization folders Disabled.
                A separate approved lab folder may explicitly use "ExistingExternalUserSharingOnly".
                Grant lab preview via Visitors Read or Specific people - Can view links;
                never Team/Members membership, which grants edit rights. Check other grants.
                "ExternalUserSharingOnly" is a lab-only option for approved invitations.
                No anonymous/Anyone links. The kit does not invite guests or change tenant policies.
                Leadership and Program Governance sites remain internal-only and allowlisted.
                The standard Governance and Responsible AI channel is on the parent site;
                review it and all other parent-site content before inviting preview guests.
                To turn OFF now: SharePoint admin center > Active sites > select CoE site >
                Settings > More sharing settings > Only people in your organization > Save.
                Then set this property to "Disabled" BEFORE the next install/resume/update;
                reruns apply this setting, and omission defaults to Disabled.
                Verify SharingCapability is Disabled. Remove Visitors grants and view links.
                If guests were previously added to the Team, remove that membership too.
                The closing ADMIN HANDOFF reports actual ON/OFF, WHY OFF, and shutdown steps.
                Tenant/Teams/Groups/Entra/label/access policies can still block guest sign-in;
                test each intended lab guest. Do not loosen tenant policy to complete a build.
  OrganizationEmailDomains
                Organization UPN domains used to flag guest/out-of-domain parent Team members
                for review, not to reject named preview guests. The governance-channel
                check separately resolves immutable user IDs and tenant IDs; a matching email domain alone
                is not proof of tenant identity.
  GovernanceAdditionalAllowedMembers
                Explicit in-tenant UPN allowlist for governance shared-channel members beyond
                SharedChannelOwnerUPN. Effective Graph allMembers (including indirect members) and shared-Team
                relationships are checked before publishing; unknown, cross-tenant, or unapproved access stops it.

Naming is resolved identically by install and update. Explicit command-line OrgName, OrgNoun,
ShortName, DisplayName and SampleNotice override this file, including blank values that request
their documented defaults. Replace organization placeholders before signing in; unresolved
{{tokens}} and invalid naming values are rejected before any tenant login.
The optional update switch -RepairCapturedPages (Scope Guides or All) repairs the kit's captured
Home, adoption, roles and Microsoft Mechanics pages. Review existing custom page edits before
opting in; ordinary updates leave these pages alone.

Content\   OPTIONAL. Replace any kit text file by putting your version at the same path
           as in the kit's SeedContent folder. Start from a copy of the kit file, then edit it.
             Content\Sections\04-Service-Catalog-and-Support.md     (set actual service scope and support routes)
             Content\Sections\03-Governance-and-Responsible-AI.md   (your governance page)
             Content\Sections\Sections.json                         (ADD a section/channel, or REMOVE one;
                                                                     copy the whole kit file first - Runbook 6.3)
             Content\Sections\07-Our-Section.md                     (the page for a section you added)
             Content\Sections\Files\<channel>\...                   (sample files placed in a channel)
             Content\Give-Feedback.md                               (Give Feedback page and incident route)
             Content\Copilot-FAQs.md                                (FAQ page)
             Content\Guides\02-Students-and-AI.md                   (your student guide)
             Content\Guides\00b-Is-This-OK.md                       (your data levels and risk ratings)
             Content\Guides\10-Concerns-and-Myths.md                (answers in your policy's words)
             Content\Guides\11-Champions-Toolkit.md                 (your champions space and resources)
               The kit ships generic versions of these three and of 00a-Start-in-10-Minutes.md.
               They use a common Public / Internal / Confidential pattern; replace it with yours.
               An empty file omits a guide and removes its managed navigation links.
               Previously published pages are preserved; retire them separately after review.
               Other guides link to Is-This-OK, so keep that one.
             Content\Guides\12-Our-Own-Guide.md                     (adds a new guide)
             Content\Guides\05-Agents.md as an EMPTY file           (removes that kit guide)
             Content\Training-Calendar.csv                          (your session offsets; copy the current
                                                                     StartOffsetDays schema, never fixed dates)
             Content\Learning-Paths.json                             (sequenced role learning; stable IDs)
             Content\CoE-Revision-Content.json                      (champion page intro, governance Start here text)
             Content\Experience\Guided-Learning.json                (reviewed Microsoft Learn course cards)
             Content\Experience\Tools.json                          (reviewed tool comparison and destinations)
             Content\ResourceLinks.json                             (legacy template setup, not shown on 3.7 Home)
             Content\Governance\program|leadership\...              (governance drafts; -Scope Governance -ReplaceFiles)
             Content\Higher-Ed-AI-Governance-Framework-DRAFT.md     (organization-wide AI policy draft;
                                                                     an EMPTY file leaves the proposed policy/link out;
                                                                     previously hosted policy files are preserved)
           Tokens {{OrgName}} {{OrgNoun}} {{OrgShort}} {{SupportEmail}} work in any file;
           {{MailTo:Subject}} becomes an email link to SupportEmail; {{Link:ServiceDesk|text}}
           links to an address in Links. {{IfRouteMissing:DataSafetyIncident|text}} shows text only
           when that Links route is empty (fallback guidance readers do not need once routes exist).

LEARNING PATHS AND AGENT CATALOG UPGRADE
  The existing Training and Enablement page/Teams tab embeds the native Copilot Learning Paths list:
  18 starter steps across Faculty, Staff, Students, Champions, IT and Agent makers.
  Fields cover path/audience/step, practice time, requirement, product/access, Learn/Practice links,
  expected result, owner/review date and an optional LMS link. The top-of-page Learning steps view has
  four fields: name, step, Learn and Practice, with roles expanded in Faculty, Staff, Students,
  Champions, IT and Agent makers order. Rows wrap in narrow panes. Select a name for full details,
  including practice time. Learning ID and the audience sort key are hidden from forms.
  Assign actual content owners and record review dates only after review; blank metadata produces warnings.
  Full management views remain: By audience, By path and Required.
  Copy SeedContent\Learning-Paths.json into your organization's Content folder to tailor or opt out:
  version 1 and items [] seeds nothing; existing learning rows are never deleted.
  Each row's id is stable and unique; inserts only. Existing edits are not replaced when seed text changes.
  On first enabling approval, existing learning rows and new starter learning rows are approved for
  display, without filling owner/review dates or claiming completed institutional training.
  Keep relative SitePages links only for guides your organization retains. Replace omitted-guide links
  with an approved resource. No prompt CSVs, unapproved decision-support prompts or private records are imported.
  Default Practice links use named headings in Guides\07-Prompt-Library.md, for example
  SitePages/Guide-Prompt-Library.aspx#clear-communication. Missing local prompt headings stop publication.
  Revision 3.2 moved Rubric builder, Action list from your notes and Clear communication into named
  headed sections, reworded those exercises and added Course description editor, student study prompts
  and a champion pattern. The safer wording uses public/synthetic or explicitly permitted practice text.
  An org override of Guides\07-Prompt-Library.md must retain the matching headings or override affected
  practiceUrl values. This validation checks source headings, not SharePoint's rendered link behavior.
  Links.PromptLibrary replaces the whole default practice destination, not just its page path;
  supply per-row practiceUrl deep links in Content\Learning-Paths.json for a different prompt library.

  The existing Agent Showcase page puts compact Published/Featured views above its guidance.
  Both are ALWAYS embedded, even when empty, with neutral guidance independent of current row counts.
  Native approval is the only publication gate; status Retired excludes an agent, and Featured also
  requires AgentFeatured. Legacy Submitted, Published, In review and Rejected status labels are retained
  for compatibility but do not add another publication step. Blank status also permits approved display.
  Review view contains only pending, non-retired entries. Retired/Rejected legacy rows and new seeds
  are set to native Rejected when initially migrated/inserted; existing approval states are not rewritten.
  Agent details retains all metadata;
  All Items and Agent details exclude Retired rows. Both new and existing lists default to Published.
  Manage all entries retains every status for reviewers to find pending retirement changes.
  New fields: type/product, sources, connections/actions, access/billing, allowed data, backup,
  support, last/next review and Featured. Existing agent URLs, metadata and list ID are kept.
  On first enabling approval, previously Published/Featured agents stay approved, Retired/Rejected
  rows become rejected and other rows become pending. Reruns never reapprove pending/rejected revisions.
  {{AgentList}} is retained for older content overrides and renders as empty text; the list-backed views carry the content.
  To publish: review the metadata/evidence, select Featured before approval if appropriate, then use
  SharePoint Approve/Reject to approve a non-retired item. No status Published step is required.
  To retire: set status Retired, then switch to Manage all entries and approve that change.
  The pending Retired row is excluded from Review and reader views, so use the management view.
  Readers may still see the previous approved version until retirement is approved.
  Approval does not change Retired back to an active status; the approved Retired row is not discoverable.
  The view predicates update from list data without rerunning 03_Update. Catalog publication never shares an agent.
  Editing an approved item or changing Featured may return it to Pending. In an isolated GCC test,
  both edits became Pending and the actual reader retained the last approved version, not the new edit.
  Reapproval exposed the new description or Featured flag. Verify this in your own tenant before rollout.
  If an edit becomes pending, review it and approve again; do not disable approval to avoid this.
  Before production: install with both views empty, approve a Submitted test agent without
  changing its status, then feature/edit it and check reader visibility after each operation. Open
  at least Clear communication and Course description editor Practice links in published SharePoint,
  including after saving the page in the modern editor. Verify the rendered fragment and actual scroll
  target, not just the generated HTML. No live-site result is claimed by the offline tests.
  Also check the organization's Training and Enablement override for references to the removed four-week sample.
  Review inherited Edit/Full Control grants: users with ApproveItems can approve; users with ManageLists
  can change approval settings. The installer does not silently revoke those existing grants.
  If an earlier kit downgraded writers to Read, it cannot infer their previous grants. Review and restore
  only intended permissions manually; it does not reset inheritance or widen unique item permissions.
  Existing customer page overrides remain yours. Keep their submission/publication wording consistent
  with local permissions and approval. Sensitive review evidence belongs in restricted governance.
  Run 03_Update-CoEContent.ps1 -OrgPath <folder> -Scope Guides to apply the catalog upgrade
  on an existing site after review. Managed pages are republished with RevisionAudit copies;
  a resume without managed-page replacement preserves pages and does not retrofit their web parts.
  This command is a LIVE update. Review and test in a non-production CoE before customer rollout.

   Success Stories uses the same native approval-only model. Its Published view is the default.
   New starter stories are Submitted/pending, with no claimed measured savings or mock videos.
   Authentic legacy Published stories retain their visibility on first migration; old SAMPLE or
   MOCK-linked stories become pending. Previously moderated rows and customer edits are preserved.
   Use Manage all entries to review a pending retirement. Hosting a video does not approve it or
   restrict its file permissions. Draft files must remain restricted to the intended reviewers.

REVISION 3.6 - COPILOT PROMPT LIBRARY (RETAINED IN 3.7)
  A new list, Copilot Prompt Library (Lists/CopilotPromptLibrary), shows ready-made Copilot prompts
  grouped by department, with views By task type, Copilot work (license needed), Review and Manage all
  entries. It appears on the "Prompt library by role" page under "Organization prompt library".
  Its rows come from CSV files in the Microsoft 365 admin center import format, read without changes:
    Higher education   the kit's base set, SeedContent\OrgPrompts\highered_prompt_library_*.csv (230)
    Government         ContentPacks\Government-StateLocal\Content\OrgPrompts\gcc_prompt_library_import_*.csv
                       (230); the pack also has empty higher-ed files so those are left out
  Add your organization's own prompts in <OrgPath>\Content\OrgPrompts (see the README there).
  Base and organization prompts are inserted approved; prompts people add on the site need approval.
  The list is insert-only by Title + Locale: reruns add new prompts and never change existing rows.
  New setting: "PromptLibrary": "On" (default) or "Off".
  Expect about 5-10 extra minutes on a first install while 230 prompts are added.

REVISION 3.5 - ONE KIT FOR HIGHER EDUCATION AND GOVERNMENT
  The kit's built-in content (SeedContent) is still written for higher education. Government and other
  sectors use the same scripts with a content pack: an organization folder whose Content\ files replace
  the higher-ed text. GCC-Moderate tenants use the commercial endpoints (sharepoint.com,
  graph.microsoft.com), so nothing in the scripts changes for them. GCC High and DoD are not supported.

  Five things that were fixed to higher education are now settings. Leave them out to keep the
  higher-ed behavior exactly as before.
    GuidesIntro          One sentence under "Copilot guides" on the guide hub page.
                         Default: "Practical guidance for faculty, staff, students, and IT. ..."
    StoryAudiences       Audience choices on the Copilot Success Stories list, for example
                         [ "Staff", "Supervisors", "IT" ]. Default: [ "Faculty", "Staff", "Student" ].
                         Every story in Content\Sections\Sections.json must use one of them. On an
                         existing list, missing choices are added; existing choices are never removed.
    ScenarioLibraryUrl   The Teams "Scenario Library" tab, an https:// address. Default: the education
                         scenarios. Government: https://adoption.microsoft.com/en-us/scenario-library/government/
    Learning path order  No setting. Audience groups on Copilot Learning Paths now appear in the order
                         Content\Learning-Paths.json first uses them (up to 18 audiences). The order is set
                         when the list is created; on an existing list new audiences sort last.
    Roles page           The champions line now reads "Champions for each department or unit".

  To leave out a governance draft, a guide or the overarching policy draft, put an empty file at the
  same path under Content\ (unchanged behavior). The Students and AI owner-checklist item now appears
  only when that guide is published.

  Content packs ship inside the kit (3.7 and later): ContentPacks\Government-StateLocal. Copy the pack
  folder out of the kit, fill in Deployment-Settings.json, and install with -OrgPath as usual.

REVISION 3.4 - GOVERNANCE WORD LINKS AND RESOURCE REPAIR
  Governance page document links use the verified file's immutable ID in SharePoint Doc.aspx
  and open Word in a separate browser tab. Direct .docx download links are no longer used for
  these page entries. No Word document content or governance permissions need to change.
  Open both Leadership and Program Start here tabs in Teams after refreshing them, and check
  a document link from each. The policy-draft link uses the same Word-opening route.
  The isolated test opened all thirteen governance documents in Word web with no downloads.
  This confirms Word web behavior; it does not claim every machine can launch desktop Word.

  Install/resume explicitly creates and verifies expected standard channels and resource tabs
  from the prepared definitions. Runtime channel/file/app identities are checked, captured
  source IDs are not reused, and captured welcome posts are not replayed on resume.
  Custom or unrelated same-name tabs are retained rather than silently removed.
  Content updates preserve an intentionally removed Top 10 tab by default. Use:
    .\03_Update-CoEContent.ps1 -OrgPath <folder> -Scope All -EnsureResourceTabs
  only when you intend to restore required resource tabs. Other update scopes reject that switch.
  Revision 3.4 also includes the catalog fixes found in the isolated test: explicit new-list
  read-back and typed UInt32 view limits.

REVISION 3.4.2 - NAVIGATION RENAMES AND READER-FACING TEXT
  Renaming a Quick Launch link also renames the SharePoint page it points to and leaves that page as an
  unpublished draft (verified on a live tenant). 3.4.1 renamed four links (Learn, Agents, Get help,
  Governance), so those pages showed "Draft" to owners and their titles no longer matched the Teams tabs.
  3.4.2 replaces a link that needs a new label (add the new link, copy its children, remove the old one)
  instead of renaming it. Page titles and publishing state are unchanged.

  Fallback text for a missing support route now appears only when that route is missing. Content files use
  {{IfRouteMissing:<Route>|text}}; with every route configured, readers no longer see "if the link says
  route not configured" on ten pages. The Support and incident routes block drops its fallback paragraph
  for the same reason.

  Reader-facing wording no longer includes setup notes meant for the CoE team ("starter service examples
  ... before launch", "legacy Published value", "Kit dates are samples", "(Links will be added by the CoE
  team.)", repeated "check back later" lines on the Agent Showcase). An empty TrainingLinks or
  GovernanceLinks list now renders nothing. Keep these notes in this README, not on reader pages.

  Repairing a site built with 3.4.1: run .\03_Update-CoEContent.ps1 -OrgPath <folder> -Scope All, then
  Test-CoEInstall.ps1. Pages that 3.4.1 left as drafts with renamed titles are rewritten and published by
  the update; existing renamed navigation links keep their new labels.

REVISION 3.4.1 - REVIEWER GROUP, LIVE VERIFICATION AND RUN LOGS
  Catalog reviewers now belong to one SharePoint group, "CoE Catalog Reviewers", which holds the
  "CoE Catalog Reviewer" permission level (Contribute plus approval) on each catalog list. Earlier
  builds updated each reviewer's own entry on the list, which fails whenever the reviewer only held
  Limited Access: SharePoint does not copy that entry when a list stops inheriting permissions.
  To add or remove a reviewer later, edit the group in SharePoint; no script rerun is needed.
  The site Owners keep Full Control and no other existing grant is changed.

  Every run of 02_Install and 03_Update writes a transcript to <your organization folder>\RevisionAudit\
  <run id>-transcript.txt, including runs that fail. Send that file when asking for help.

  After every install or update, run the read-only check and confirm it prints ALL CHECKS PASSED:
    .\Test-CoEInstall.ps1 -OrgPath <folder> -SiteUrl <the CoE site address>
  It checks pages, Home tiles, navigation order, catalog approval and reviewer access, reader views and
  the support routes, and exits with a non-zero code if anything is wrong.

  Test-CoELiveRegression.ps1 is for kit maintainers. It exercises SharePoint behaviours that offline
  tests cannot (view addresses with spaces, how SharePoint stores view queries, reviewer grants after
  inheritance is broken) against a scratch site, and refuses any site whose address lacks "Scratch".

  Do not use -ResumeExisting to validate a kit change. It keeps existing pages and skips the Home,
  navigation and page repairs, so a run that completes this way does not prove the new version.
  Validate with a plain install into a new alias or after a full removal (04_Remove-CopilotCoE.ps1).

Assets\    OPTIONAL. Files the installer offers to host. It lists what it finds in each
           folder and asks "Host these files?" before uploading (-AcceptOrgAssets = yes to all).
           Existing organization files are preserved unless -ReplaceOrgAssets is supplied;
           replacement uploads in place without first deleting the working file.
           Recovery depends on library version settings. -AcceptOrgAssets approves new hosting only.
  Top10\            exactly one .pptx -> "Top 10 to try" tab in Ask Us Anything
  RAI-Policies\     AI / Responsible AI policy PDFs -> Governance and Responsible AI > Official Documents
  Roadmap\          Copilot roadmap decks -> Feedback and Roadmap > Roadmap Decks
  Success-Stories\  videos (.mp4) -> Success Stories > Videos
  Training\         decks, handouts, recordings -> Training and Enablement > Training Materials
  Service-Catalog\  forms, service descriptions -> Service Catalog and Support > Service Documents
  Agents\           agent guides, demo recordings -> Agent Showcase > Agent Guides
  <your folder>\    for a section you added, if its Sections.json entry has an orgAssets block
Every hosted file is listed with a link on its section page. Re-run 03 -Scope Guides
(or -Scope All for the Top 10 deck) after adding files.

=====================================================================================
EDIT THESE DIRECTLY IN SHAREPOINT OR TEAMS (the scripts do not overwrite them)
=====================================================================================
  Home page hero, News, image and other web parts (not the Resources card links or Learning Series)
  Copilot Adoption Checklist rows; Department Champions rows; Training Calendar events;
  Success Stories and Agent Showcase list rows
  Roles and Contacts, Adoption Guide, Technical Readiness, News and Updates,
  and Microsoft Mechanics pages (03 -Scope All only removes retired Early Access Program links)
  Share Your Prompt and Ask Us Anything tabs (03 -Scope All re-points "Top 10 to try"; if you
  delete that tab it is not re-added)
  Conversations, Documents, Notebook links (hide them in Edit navigation)
  Team name, site name, logo (02 resets the logo), theme, channel membership
  Pages listed in Content\ above ARE replaced by 03; make those changes in Content\ instead.

=====================================================================================
BEFORE A PURGE (04 -Purge) - BACK UP THIS WHOLE FOLDER
=====================================================================================
  This folder is what lets you rebuild the same CoE: settings, Content\ overrides,
  and Assets\ files. Save all of it, not just Deployment-Settings.json, and keep it
  outside the kit folder (for example C:\CoE-Orgs\<org>) so re-extracting the kit
  cannot touch it. Export anything added by hand in SharePoint or Teams too.
  Full steps: Installation Runbook section 10.1.

  The installer also writes CoE-Revision-Report.json into this folder: the addresses of
  every page and channel site it built. 03_Update needs it, and 04_Remove deletes it.
  One organization folder per CoE, so several CoEs can be built from the same kit.
=====================================================================================
OWNER LAUNCH CHECKLIST - KEPT OFF THE PUBLIC PAGES
=====================================================================================
  Setup reminders (incident route, real support mailbox, tool entitlements, champion
  appointments, calendar, removing the sample line) appear only on the Program Governance
  Start here page, under "Owner launch checklist (CoE owners only)". Public pages carry
  no setup instructions. Work through that list before inviting the wider audience.
Do not put passwords, tokens, or confidential records in this folder.